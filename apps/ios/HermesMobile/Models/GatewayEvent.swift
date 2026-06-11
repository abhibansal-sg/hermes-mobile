import Foundation

/// A server-push event from the hermes gateway
/// (`{method: "event", params: {type, session_id?, payload?}}`).
struct GatewayEvent: Sendable {
    let type: GatewayEventType
    /// The raw wire string for `type` (kept for `.unknown` diagnostics).
    let rawType: String
    let sessionId: String?
    let payload: JSONValue

    /// Stored (persistent) session id, present on frames mirrored to
    /// non-owning clients by the gateway's multi-client broadcast
    /// (HERMES_GATEWAY_BROADCAST=1). Lets a client correlate a foreign
    /// runtime session with the stored session it has open.
    let storedSessionId: String?

    /// Coalesced count of frames the gateway dropped from this client's
    /// broadcast backlog before this frame (F3 head-of-line overflow policy).
    /// The gateway adds `broadcast_gap` at the FRAME TOP LEVEL (a sibling of
    /// `method`/`params`, NOT inside `params`), so it is threaded in from
    /// `JSONRPCInboundFrame.broadcastGap` at the construction site. A non-nil
    /// positive value means the live stream has a hole and the client must
    /// reconcile via REST backfill. `nil`/0 on every normal frame.
    let broadcastGap: Int?

    /// - Parameter broadcastGap: the frame-top-level dropped-frame marker,
    ///   passed through from `JSONRPCInboundFrame.broadcastGap` (the wire carries
    ///   it as a sibling of `params`, so it cannot be recovered from `params`).
    init?(params: JSONValue, broadcastGap: Int? = nil) {
        guard let rawType = params["type"]?.stringValue else { return nil }
        self.rawType = rawType
        self.type = GatewayEventType(rawValue: rawType) ?? .unknown
        self.sessionId = params["session_id"]?.stringValue
        // Prefer the explicit frame-top-level value; fall back to a params-nested
        // lookup defensively only (the real wire never nests it there).
        let gap = broadcastGap ?? params["broadcast_gap"]?.intValue
        self.broadcastGap = (gap ?? 0) > 0 ? gap : nil
        // Tolerate a numeric stored id and trim surrounding whitespace (H3
        // correlation guard): a numeric `stored_session_id` would otherwise
        // coerce to nil and silently drop every mirror frame, and an untrimmed
        // id would fail the exact-string equality in ChatStore's adoption gate.
        // An empty/whitespace-only id normalizes to nil so it can never falsely
        // match an equally-blank active id.
        if let raw = params["stored_session_id"]?.coercedStringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            self.storedSessionId = trimmed.isEmpty ? nil : trimmed
        } else {
            self.storedSessionId = nil
        }
        self.payload = params["payload"] ?? .null
    }
}

enum GatewayEventType: String, Sendable {
    case gatewayReady = "gateway.ready"
    case messageStart = "message.start"
    case messageDelta = "message.delta"
    case messageComplete = "message.complete"
    case thinkingDelta = "thinking.delta"
    case reasoningDelta = "reasoning.delta"
    case toolStart = "tool.start"
    case toolProgress = "tool.progress"
    case toolComplete = "tool.complete"
    case approvalRequest = "approval.request"
    case clarifyRequest = "clarify.request"
    case statusUpdate = "status.update"
    // F4A-A2: subagent delegation tree. The gateway normalizes the internal
    // `delegate.*` enum to these `subagent.*` names before relay
    // (server.py:2122 `_on_tool_progress`), so the wire never carries
    // `delegate.running`/`delegate.complete`. All carry the parent runtime's
    // `session_id` (and `stored_session_id` on broadcast frames), so they route
    // through the SAME ownership gate as message/tool frames.
    case subagentStart = "subagent.start"
    case subagentThinking = "subagent.thinking"
    case subagentTool = "subagent.tool"
    case subagentProgress = "subagent.progress"
    case subagentComplete = "subagent.complete"
    // F4A-A2: transient, session-local, biometric-gated secure prompts. Emitted
    // by the gateway as standard `event` notifications carrying the requesting
    // runtime's `session_id` (server.py:2214/2220). NOT broadcast-mirrored to
    // other clients, so they are always local to the runtime that needs them.
    case sudoRequest = "sudo.request"
    case secretRequest = "secret.request"
    /// Turn-level failure. The gateway emits `error` with `{"message": ...}`
    /// when agent init or a turn raises (`tui_gateway/server.py` `_emit("error",
    /// …)` at 813/4172/4674). Previously fell through to `.unknown` and was
    /// dropped at all three routing layers, so a failed turn left the spinner
    /// streaming forever. Now routed so ChatStore clears streaming and surfaces
    /// the message.
    case error = "error"
    /// Session runtime info update. The gateway emits `session.info` after a
    /// hot-swap of model/reasoning/fast (config.set with a session_id), or when
    /// the session's cwd/personality changes. The payload is the full session info
    /// dict (`_session_info()` in server.py). Routed to `ConnectionStore` so the
    /// composer chip and popover can reflect live session state.
    case sessionInfo = "session.info"
    case unknown
}

/// Connection lifecycle for the WebSocket client. Mirrors the reference
/// TS client states (idle/connecting/open/closed/error) plus the
/// iOS-specific reconnecting phase driven by ReconnectController.
enum GatewayConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case open
    case closed(reason: String?)
    case failed(String)
}
