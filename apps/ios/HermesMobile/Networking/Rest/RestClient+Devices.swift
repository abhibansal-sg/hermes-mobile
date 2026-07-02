import Foundation

/// Typed errors specific to `POST /api/devices/issue`.
enum DeviceIssueError: Error, LocalizedError, Equatable, Sendable {
    /// The gateway refused to mint another device token because the registry is
    /// at its configured cap. This is permanent until a device is revoked, so
    /// callers must NOT treat it like a transient transport/status failure.
    case limitReached(maxDevices: Int?)

    var errorDescription: String? {
        switch self {
        case .limitReached(let maxDevices):
            if let maxDevices {
                return "Device limit reached (\(maxDevices) devices). Revoke an unused device in Settings → Devices, then retry."
            }
            return "Device limit reached. Revoke an unused device in Settings → Devices, then retry."
        }
    }
}

/// Typed errors specific to `DELETE /api/devices/{id}`.
enum DeviceRevokeError: Error, LocalizedError, Equatable, Sendable {
    /// The gateway cut the token/socket in the live process, but failed to write
    /// the registry file. The revocation is therefore not durable across restart.
    case persistFailed(RevokeDeviceResult)

    var errorDescription: String? {
        switch self {
        case .persistFailed(let result):
            let socketCopy = result.socketsClosed == 1 ? "1 live socket" : "\(result.socketsClosed) live sockets"
            return "Device was not durably revoked. The server closed \(socketCopy), but failed to save the registry change; it may return after a gateway restart. Try again."
        }
    }
}

// MARK: - W3A-A per-device-token REST surface (feature-detected)
//
// The four NEW per-device-token endpoints (`GET /api/devices`, `POST
// /api/devices/issue`, `DELETE /api/devices/{id}`, `GET /api/approvals/audit`)
// plus their zero-side-effect capability probe. Kept on `RestClient` (mirroring
// `RestClient+FS.swift` / `RestClient+Profiles.swift`) so they inherit the
// loopback `Host` override, the `X-Hermes-Session-Token` auth header, the
// ephemeral session, and the 15s timeout via the shared `makeRequest`/`get`/
// `perform`/`decode` plumbing — no cloned HTTP code.
//
// MIGRATION SAFETY: every caller in `ServerCapabilities` / `ConnectionStore`
// gates on `capabilities.devices == .available`, so on a stock hermes-agent (no
// device routes) none of this is reached and the app is byte-for-byte its
// pre-W3a self. The probe is EAGER + side-effect-free.
//
// SECRETS HYGIENE (binding): the device token is NEVER logged. `RestError`
// already truncates bodies to 512 chars in `perform`, but a device token would
// only ride in the `issueDevice` 200 body, which goes through a typed decode
// into ``IssuedDevice`` (never error-logged on the happy path) and is consumed
// straight into the Keychain by the caller. No method here prints a token.
extension RestClient {

    // MARK: - Capability probe (eager, side-effect-free)

    /// Side-effect-free probe of `GET /api/devices` — the device-token list,
    /// which is the route NEW in W3a. A W3a server returns `200` with a
    /// well-formed `{"devices":[…]}` body (route exists ⇒ available — even an
    /// EMPTY registry is a 200, NOT a 404, so the panel renders with zero rows);
    /// a stock gateway has no such route and returns `404`/`405` (unavailable).
    /// The probe is a READ — no device is issued, listed-with-side-effect, or
    /// revoked. Never throws — failures map to `.inconclusive`. Shapes its result
    /// as the SAME ``UploadProbeResult`` the upload/fs/profiles probes use so
    /// ``ServerCapabilities`` folds all four with one switch.
    ///
    /// Refinement (mirroring `probeProfilesEndpoint`): a `200` must ALSO carry a
    /// `devices` array to count as `.available`; a `200` lacking one is
    /// `.inconclusive` (defensive against a same-path collision on a non-W3a
    /// route that happens to 200).
    func probeDevicesEndpoint() async -> UploadProbeResult {
        let request = makeRequest(path: "\(mobileAPIPrefix)/devices", method: "GET")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .inconclusive }
            switch http.statusCode {
            case 200:
                // Confirm the body really is the devices wrapper before trusting
                // the route. `JSONSerialization` (not a typed decode) so a missing
                // optional field can't downgrade a genuine `200` to inconclusive.
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["devices"] is [Any] {
                    return .available
                }
                return .inconclusive
            case 404, 405:
                return .unavailable
            default:
                return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }

    // MARK: - List paired devices (the panel's data)

    /// `GET /api/devices` → decode `{"devices":[…]}` into the ``PairedDevice``
    /// rows the Devices panel renders. Server sorts `last_seen` desc
    /// (most-recent-first). NEVER carries the token (only `token_prefix`).
    /// Decoded with the models' explicit `CodingKeys` (`.useDefaultKeys` — the
    /// wire keys are snake_case and the models map them, so no double-transform).
    /// Throws ``RestError`` (e.g. `badStatus(401, …)` on a bad/absent credential)
    /// for the caller to map to a native inline error.
    func devicesList() async throws -> [PairedDevice] {
        let data = try await get(path: "\(mobileAPIPrefix)/devices")
        return try decode(
            DevicesListResult.self,
            from: data,
            context: "devices.list",
            strategy: .useDefaultKeys
        ).devices
    }

    // MARK: - Issue a device token (the ONE-TIME grant — auto-upgrade + re-pair)

    /// `POST /api/devices/issue {"device_name","platform"}` → mint a device token
    /// and return it ONCE in ``IssuedDevice``. The caller MUST persist the
    /// returned `token` to the Keychain immediately (secrets hygiene). On a
    /// registry-write failure the server returns `500`
    /// `{"error":"registry persist failed"}` (the token is NOT returned) which
    /// surfaces here as ``RestError/badStatus``; the auto-upgrade path catches
    /// that and KEEPS the shared token (no regression). `409` on a full device
    /// registry throws ``DeviceIssueError/limitReached(maxDevices:)`` so callers
    /// can surface an actionable, non-retryable condition. `401` on a bad/absent
    /// credential.
    ///
    /// `platform` defaults to `"ios"`. `deviceName` is sanitized server-side
    /// (control chars stripped, collapsed, truncated to 64, defaulted to
    /// `"iPhone"` if empty).
    func issueDevice(name: String, platform: String = "ios") async throws -> IssuedDevice {
        var request = makeRequest(path: "\(mobileAPIPrefix)/devices/issue", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object([
            "device_name": .string(name),
            "platform": .string(platform),
        ])
        request.httpBody = try encodeBody(body, context: "devices.issue")
        let data: Data
        do {
            data = try await perform(request)
        } catch RestError.badStatus(409, let body) {
            throw DeviceIssueError.limitReached(
                maxDevices: Self.issueDeviceLimitMaxDevices(from: body)
            )
        }
        return try decode(
            IssuedDevice.self,
            from: data,
            context: "devices.issue",
            strategy: .useDefaultKeys
        )
    }

    /// Extract `max_devices` from the gateway's device-limit body. Kept tolerant
    /// (number or numeric string) so the typed 409 survives minor server encoder
    /// changes while non-409 behavior remains the shared ``RestError`` path.
    private static func issueDeviceLimitMaxDevices(from body: String) -> Int? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["max_devices"] else { return nil }
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    // MARK: - Revoke a device (the panel's destructive action)

    /// `DELETE /api/devices/{device_id}` → invalidate that device's token
    /// IMMEDIATELY (no grace window) and best-effort cut its live WS socket(s).
    /// `200 {"revoked":true,"device_id":…,"sockets_closed":N}`. `404` on an
    /// unknown id, `401` on a bad/absent credential — both arrive as
    /// ``RestError/badStatus`` for the caller to surface inline. A persist
    /// failure returns `500` `{"error":"revocation persist failed","revoked":true,
    /// …}` (the token is already dead in the server process; the on-disk file is
    /// stale) — mapped to ``DeviceRevokeError/persistFailed`` so callers do not
    /// present it like a clean revoke. Revoking a device NEVER affects the shared
    /// token.
    @discardableResult
    func revokeDevice(id deviceId: String) async throws -> RevokeDeviceResult {
        let encodedId = deviceId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? deviceId
        let request = makeRequest(path: "\(mobileAPIPrefix)/devices/\(encodedId)", method: "DELETE")
        let data: Data
        do {
            data = try await perform(request)
        } catch RestError.badStatus(500, let body) {
            if let result = Self.revokePersistFailureResult(from: body) {
                throw DeviceRevokeError.persistFailed(result)
            }
            throw RestError.badStatus(500, body: body)
        }
        return try decode(
            RevokeDeviceResult.self,
            from: data,
            context: "devices.revoke",
            strategy: .useDefaultKeys
        )
    }

    /// Extract the special revoke-persist-failure shape from a 500 body. This is
    /// NOT a clean revoke: the token is dead in the current server process, but
    /// the registry write failed, so the revocation is not durable.
    private static func revokePersistFailureResult(from body: String) -> RevokeDeviceResult? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String,
              error == "revocation persist failed",
              let revoked = object["revoked"] as? Bool,
              revoked else { return nil }

        let deviceId = object["device_id"] as? String ?? ""
        let socketsClosed: Int
        if let value = object["sockets_closed"] as? Int {
            socketsClosed = value
        } else if let value = object["sockets_closed"] as? NSNumber {
            socketsClosed = value.intValue
        } else if let value = object["sockets_closed"] as? String, let parsed = Int(value) {
            socketsClosed = parsed
        } else {
            socketsClosed = 0
        }
        return RevokeDeviceResult(revoked: true, deviceId: deviceId, socketsClosed: socketsClosed)
    }

    // MARK: - Approval audit log (read-only)

    /// `GET /api/approvals/audit?limit=…[&session_id=…]` → the append-only audit
    /// tail, most-recent-first. `limit` is clamped server-side (cap 500). NEVER
    /// carries a full token (only `token_prefix` + `device_id`). Missing/corrupt
    /// log → `{"entries":[]}` (200). `401` on a bad/absent credential
    /// (``RestError/badStatus``).
    func approvalAudit(limit: Int = 100, sessionId: String? = nil) async throws -> [ApprovalAuditEntry] {
        var components = URLComponents()
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let sessionId, !sessionId.isEmpty {
            items.append(URLQueryItem(name: "session_id", value: sessionId))
        }
        components.queryItems = items
        let query = (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
        let path = query.isEmpty
            ? "\(mobileAPIPrefix)/approvals/audit"
            : "\(mobileAPIPrefix)/approvals/audit?\(query)"
        let data = try await get(path: path)
        return try decode(
            ApprovalAuditResult.self,
            from: data,
            context: "approvals.audit",
            strategy: .useDefaultKeys
        ).entries
    }

    /// `POST <plugin>/debug-share` — server-side redacted debug bundle upload.
    ///
    /// Served by the hermes-mobile plugin mount only. The server imports and calls
    /// the same `build_debug_share` core as desktop `/api/ops/debug-share`, with
    /// redaction forced on. The response is shareable paste URLs for support.
    func debugShareReport() async throws -> DebugShareReport {
        var request = makeRequest(path: "\(mobileAPIPrefix)/debug-share", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await perform(request)
        return try decode(
            DebugShareReport.self,
            from: data,
            context: "debug.share",
            strategy: .useDefaultKeys
        )
    }
}

/// Server-generated debug-share bundle returned by the hermes-mobile plugin.
///
/// The backend forces redaction on before upload; this model carries only the
/// returned paste URLs + upload diagnostics for the Settings share sheet.
struct DebugShareReport: Decodable, Identifiable, Sendable, Equatable {
    let id = UUID()
    let ok: Bool
    let urls: [String: String]
    let failures: [String]
    let redacted: Bool
    let autoDeleteSeconds: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case urls
        case failures
        case redacted
        case autoDeleteSeconds = "auto_delete_seconds"
    }

    var sortedURLLabels: [String] {
        urls.keys.sorted { lhs, rhs in
            if lhs == "Report" { return true }
            if rhs == "Report" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    var shareText: String {
        sortedURLLabels
            .compactMap { label in
                guard let url = urls[label], !url.isEmpty else { return nil }
                return "\(label): \(url)"
            }
            .joined(separator: "\n")
    }
}
