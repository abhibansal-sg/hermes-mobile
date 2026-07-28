import Foundation

/// A server-push event from the hermes gateway
/// (`{method: "event", params: {type, session_id?, payload?}}`).
struct GatewayEvent: Sendable {
    let type: GatewayEventType
    /// The raw wire string for `type` (kept for `.unknown` diagnostics).
    let rawType: String
    let sessionId: String?
    let payload: JSONValue

    /// Optional stored (persistent) session id carried by enriched event
    /// producers. Runtime id remains the stock routing authority.
    let storedSessionId: String?

    init?(params: JSONValue) {
        guard let rawType = params["type"]?.stringValue else { return nil }
        self.rawType = rawType
        self.type = GatewayEventType(rawValue: rawType) ?? .unknown
        self.sessionId = params["session_id"]?.stringValue
        // Tolerate a numeric stored id and trim surrounding whitespace (H3
        // correlation guard): a numeric `stored_session_id` would otherwise
        // coerce to nil and silently drop every mirror frame, and an untrimmed
        // id would fail exact stored-session comparisons.
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
    // `session_id`, so they route through the SAME ownership gate as
    // message/tool frames.
    case subagentStart = "subagent.start"
    case subagentThinking = "subagent.thinking"
    case subagentTool = "subagent.tool"
    case subagentProgress = "subagent.progress"
    case subagentComplete = "subagent.complete"
    // F4A-A2: transient, session-local, biometric-gated secure prompts. Emitted
    // by the gateway as standard `event` notifications carrying the requesting
    // runtime's `session_id` (server.py:2214/2220), so they are local to the
    // runtime that needs them.
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
