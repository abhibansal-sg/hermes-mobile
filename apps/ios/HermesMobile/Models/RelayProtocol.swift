import Foundation

// Wave-2 relay↔phone wire types (docs/RELAY-PHONE-PROTOCOL.md — RATIFIED
// 2026-07-18). These decode the NEW relay item stream and are ADDITIVE: the app
// still talks the legacy blob stream today (GatewayEvent). This layer is wired
// to a mock now (see RelayMockHarness) and the app flips to the live relay in a
// later convergence wave. Nothing here touches the legacy path.

// MARK: - Downstream envelope (§1)

/// One downstream frame from relay → phone:
/// `{ seq, sid, turn, kind, body }` (RELAY-PHONE-PROTOCOL §1).
///
/// - `seq` is monotonic per phone-CONNECTION (not per session) — the reliability
///   spine for ack/replay (§4).
/// - `sid`/`turn` identify the session + turn the frame belongs to; the phone
///   demuxes by these.
/// - `kind` selects the payload shape (§3); `body` is the kind-specific payload,
///   kept as an untyped `JSONValue` and projected by the typed accessors below.
struct RelayFrame: Sendable, Equatable, Codable {
    let seq: Int
    let sid: String
    /// Absent on connection-scoped frames (e.g. a `status` heartbeat).
    let turn: String?
    let kind: RelayFrameKind
    let body: JSONValue

    init(seq: Int, sid: String, turn: String?, kind: RelayFrameKind, body: JSONValue) {
        self.seq = seq
        self.sid = sid
        self.turn = turn
        self.kind = kind
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case seq, sid, turn, kind, body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.seq = try c.decode(Int.self, forKey: .seq)
        self.sid = try c.decode(String.self, forKey: .sid)
        self.turn = try c.decodeIfPresent(String.self, forKey: .turn)
        let rawKind = try c.decode(String.self, forKey: .kind)
        self.kind = RelayFrameKind(wire: rawKind)
        self.body = try c.decodeIfPresent(JSONValue.self, forKey: .body) ?? .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(sid, forKey: .sid)
        try c.encodeIfPresent(turn, forKey: .turn)
        try c.encode(kind.wire, forKey: .kind)
        try c.encode(body, forKey: .body)
    }
}

/// The frame kinds relay → phone (RELAY-PHONE-PROTOCOL §3). `.unknown` preserves
/// any wire kind a newer relay introduces so an old phone round-trips it losslessly
/// instead of failing to decode.
enum RelayFrameKind: Sendable, Equatable {
    case itemStarted        // body = item skeleton (item_id, type, ord, status=in_progress)
    case itemDelta          // body = { item_id, patch }
    case itemCompleted      // body = FULL authoritative item (status completed/failed)
    case turnStarted        // turn boundary
    case turnCompleted      // turn boundary; body carries `usage`
    case approvalRequest    // interactive gate (phone replies via RPC)
    case clarifyRequest     // interactive gate (phone replies via RPC)
    case status             // { kind, text } non-item lifecycle chatter
    case title              // session title changed
    case snapshot           // reply to resync/open: { items:[...], cursor }
    case unknown(String)

    init(wire: String) {
        switch wire {
        case "item.started": self = .itemStarted
        case "item.delta": self = .itemDelta
        case "item.completed": self = .itemCompleted
        case "turn.started": self = .turnStarted
        case "turn.completed": self = .turnCompleted
        case "approval.request": self = .approvalRequest
        case "clarify.request": self = .clarifyRequest
        case "status": self = .status
        case "title": self = .title
        case "snapshot": self = .snapshot
        default: self = .unknown(wire)
        }
    }

    var wire: String {
        switch self {
        case .itemStarted: return "item.started"
        case .itemDelta: return "item.delta"
        case .itemCompleted: return "item.completed"
        case .turnStarted: return "turn.started"
        case .turnCompleted: return "turn.completed"
        case .approvalRequest: return "approval.request"
        case .clarifyRequest: return "clarify.request"
        case .status: return "status"
        case .title: return "title"
        case .snapshot: return "snapshot"
        case .unknown(let raw): return raw
        }
    }
}

// MARK: - Typed body projections (§3)

/// An `item.delta` body: `{ item_id, patch }` (§3). `patch` is a partial-field /
/// append payload; the render lane applies it optimistically and self-heals on
/// the authoritative `item.completed` (§4).
struct RelayItemDelta: Sendable, Equatable {
    let itemID: String
    let patch: JSONValue

    init?(body: JSONValue) {
        guard let itemID = body["item_id"]?.stringValue else { return nil }
        self.itemID = itemID
        self.patch = body["patch"] ?? .null
    }
}

/// A `snapshot` body: `{ items:[...full items...], cursor }` (§3) — the
/// resume-as-items payload replayed on `resync`/`open`. The phone reconciles by
/// `item_id`.
struct RelaySnapshot: Sendable, Equatable {
    let items: [ChatItem]
    let cursor: Int?

    init?(body: JSONValue) {
        guard let rawItems = body["items"]?.arrayValue else { return nil }
        self.items = rawItems.compactMap(ChatItem.init(json:))
        self.cursor = body["cursor"]?.intValue
    }
}

extension RelayFrame {
    /// The item carried by an `item.started` / `item.completed` frame, or `nil`
    /// for other kinds / a malformed body.
    var item: ChatItem? {
        switch kind {
        case .itemStarted, .itemCompleted: return ChatItem(json: body)
        default: return nil
        }
    }

    /// The `{ item_id, patch }` payload of an `item.delta` frame.
    var itemDelta: RelayItemDelta? {
        guard case .itemDelta = kind else { return nil }
        return RelayItemDelta(body: body)
    }

    /// The full item set replayed by a `snapshot` frame.
    var snapshot: RelaySnapshot? {
        guard case .snapshot = kind else { return nil }
        return RelaySnapshot(body: body)
    }

    /// Turn-footer usage carried on `turn.completed` (§3), when present.
    var usage: UsageStats? {
        guard case .turnCompleted = kind else { return nil }
        return (body["usage"] ?? body).decoded(as: UsageStats.self)
    }
}

// MARK: - Upstream RPC methods (§1 / §5)

/// Upstream phone → relay JSON-RPC method names (RELAY-PHONE-PROTOCOL §1). The
/// relay translates these to gateway RPCs (§5). Enumerated here so the client
/// lane references a symbol, not a string literal, at every call site.
enum RelayUpstreamMethod: String, Sendable, CaseIterable {
    case submit
    case resume
    case open
    case list
    case history
    case approve
    case clarify
    case interrupt
    /// Inlined-bytes attachment (B9/A5): the relay drives the gateway's
    /// `file.attach` / `image.attach_bytes` base64 RPCs, so photo/file attach
    /// works on relay-only reaches with no gateway-REST upload round-trip.
    case attach
    case ack
    case resync
    case foreground
    /// Register this device's APNs token in the RELAY's push registry (§6a) —
    /// the relay's Notifier reads that same registry, so in relay mode the
    /// token must land HERE, not on the (possibly unreachable) gateway REST.
    case pushRegister = "push.register"
    /// Remove the APNs token from the relay's push registry (§6a).
    case pushUnregister = "push.unregister"
}
