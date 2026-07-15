import Foundation

/// Outbound JSON-RPC 2.0 request. The hermes gateway speaks JSON-RPC over a
/// WebSocket; requests carry string ids ("r1", "r2", …) mirroring the
/// reference TypeScript client (apps/shared/src/json-rpc-gateway.ts).
struct JSONRPCRequest: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: JSONValue

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }
}

/// Any inbound frame from the gateway. Three shapes share this envelope:
/// - RPC response:  has `id` + (`result` | `error`)
/// - Server event:  has `method == "event"` + `params{type, session_id?, payload?}`
/// - (Anything else is ignored.)
struct JSONRPCInboundFrame: Decodable, Sendable {
    let id: RPCID?
    let method: String?
    let result: JSONValue?
    let error: JSONRPCErrorPayload?
    let params: JSONValue?
    /// Coalesced dropped-frame count from the gateway's broadcast overflow policy
    /// (`tui_gateway/ws.py` `obj = {**obj, "broadcast_gap": dropped}`), written at
    /// the FRAME TOP LEVEL — a sibling of `method`/`params`, NOT inside `params`.
    /// Decoded here at the top level and threaded into `GatewayEvent` so the REST
    /// gap-recovery backfill (`ConnectionStore`) actually fires. The prior code
    /// read it from `params`, where it never appears, so it was structurally
    /// always nil and the backfill never ran.
    let broadcastGap: Int?

    enum CodingKeys: String, CodingKey {
        case id, method, result, error, params
        case broadcastGap = "broadcast_gap"
    }

    var isEvent: Bool { method == "event" }
    var isResponse: Bool { id != nil && (result != nil || error != nil) }
}

/// JSON-RPC ids may arrive as strings or numbers; normalize to string.
enum RPCID: Decodable, Hashable, Sendable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "RPC id must be string or number"
            )
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        }
    }
}

struct JSONRPCErrorPayload: Decodable, Sendable {
    let code: Int
    let message: String
}

/// Error surfaced to callers of `HermesGatewayClient.request`.
enum GatewayError: Error, LocalizedError, Sendable {
    /// The server answered with a JSON-RPC error frame.
    case rpc(code: Int, message: String)
    /// The socket is not connected (or dropped before the response arrived).
    case notConnected
    /// No response within the per-call timeout.
    case timeout(method: String)
    /// The response `result` failed to decode into the requested type.
    case decoding(method: String, underlying: String)
    /// Transport-level failure (URLSession error).
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .rpc(let code, let message): return "Gateway error \(code): \(message)"
        case .notConnected: return "Not connected to the Hermes gateway"
        case .timeout(let method): return "Request timed out: \(method)"
        case .decoding(let method, let underlying):
            return "Could not decode response for \(method): \(underlying)"
        case .transport(let message): return "Connection error: \(message)"
        }
    }
}

/// Well-known gateway error codes (tui_gateway/server.py).
enum GatewayErrorCode {
    static let invalidParam = 4002
    static let missingParam = 4006
    static let sessionNotFound = 4007
    static let sessionBusy = 4009
    /// `session.cwd.set` with an empty `cwd` (server.py:3258 — "cwd required").
    static let cwdRequired = 4016
    /// `session.cwd.set` against a non-existent directory (server.py:3261, the
    /// `_set_session_cwd` `ValueError` — "working directory does not exist").
    static let cwdMissing = 4017
    static let staleTruncation = 4018
}
