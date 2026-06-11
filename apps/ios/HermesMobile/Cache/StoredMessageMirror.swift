import Foundation

// MARK: - StoredMessageMirror
//
// A cache-side Codable mirror of StoredMessage. StoredMessage itself is only
// Sendable (deliberately not Codable, to keep ChatMessagePart out of the
// persistence path). This mirror lives ONLY in the cache layer and is never
// exposed to the UI or stores.
//
// Round-trip invariant: StoredMessage -> StoredMessageMirror -> encode -> decode
// -> StoredMessageMirror -> toStoredMessage() must produce an equivalent
// StoredMessage that, when fed through the existing toChatMessages path,
// renders identically to the original.
//
// See CONTRACT-OFFLINE-CACHE.md §2.2 and §2 rationale.

struct StoredMessageMirror: Codable, Sendable {
    var role: String
    var content: JSONValue
    var timestamp: Double?
    var toolCalls: [WireToolCallMirror]?
    var toolCallId: String?
    var toolName: String?
    var reasoning: String?
    var finishReason: String?

    /// Convert to the canonical StoredMessage. Always succeeds: all fields map 1:1.
    func toStoredMessage() -> StoredMessage {
        let wireCalls = toolCalls?.map { mirror in
            WireToolCall(callId: mirror.callId, name: mirror.name, arguments: mirror.arguments)
        }
        return StoredMessage(
            role: role,
            content: content,
            timestamp: timestamp,
            toolCalls: wireCalls?.isEmpty == false ? wireCalls : nil,
            toolCallId: toolCallId,
            toolName: toolName,
            reasoning: reasoning,
            finishReason: finishReason
        )
    }
}

// MARK: - WireToolCallMirror
//
// Flat Codable mirror of WireToolCall (which is only Sendable + Equatable).

struct WireToolCallMirror: Codable, Sendable {
    var callId: String
    var name: String
    var arguments: String
}

// MARK: - StoredMessage -> StoredMessageMirror

extension StoredMessage {
    /// Build a cache-side mirror from a live StoredMessage. Used when persisting
    /// transcript rows; never called on the UI path.
    func toMirror() -> StoredMessageMirror {
        let callMirrors = toolCalls?.map { call in
            WireToolCallMirror(callId: call.callId, name: call.name, arguments: call.arguments)
        }
        return StoredMessageMirror(
            role: role,
            content: content,
            timestamp: timestamp,
            toolCalls: callMirrors?.isEmpty == false ? callMirrors : nil,
            toolCallId: toolCallId,
            toolName: toolName,
            reasoning: reasoning,
            finishReason: finishReason
        )
    }
}
