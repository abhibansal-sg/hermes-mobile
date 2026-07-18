import Foundation

// Wave-2 mock item harness (docs/RELAY-PHONE-PROTOCOL.md §7). A `RelayItemSource`
// that replays a recorded/synthesized turn of relay frames so the render lane
// and the client lane can build, preview, and test against realistic item data
// with NO relay running. The fixture is reframed from the R0 spike's observed
// gateway stream (reasoning → message text → tool call → usage) into the §1
// item envelope, plus the special-render kinds (fileChange/browser/error) the
// raw R0 capture did not exercise, so every renderer branch has coverage.

/// Replays a fixed frame list to a `RelayFrameHandler`, in `seq` order, with an
/// optional inter-frame delay (0 = deliver synchronously for deterministic
/// tests; > 0 = animate a live-ish stream in previews).
struct MockRelayItemSource: RelayItemSource {
    let frames: [RelayFrame]
    /// Nanoseconds to sleep between frames. `nil`/0 delivers as fast as possible.
    let interFrameDelay: UInt64?

    init(frames: [RelayFrame] = RelayFixtures.sampleTurn(), interFrameDelay: UInt64? = nil) {
        self.frames = frames
        self.interFrameDelay = interFrameDelay
    }

    func run(onFrame: @escaping RelayFrameHandler) async {
        for frame in frames {
            if Task.isCancelled { return }
            await MainActor.run { onFrame(frame) }
            if let delay = interFrameDelay, delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }
}

/// Deterministic relay-frame fixtures. `sampleTurn()` decodes the canonical JSON
/// below; the JSON is the SOURCE OF TRUTH so the decode test round-trips exactly
/// what a mock preview renders.
enum RelayFixtures {
    static let sessionID = "3d62926c"
    static let turnID = "turn-1"

    /// One complete turn as relay frames, decoded from `sampleTurnJSON`. Traps on
    /// a malformed fixture — a decode failure here is a build-breaking bug, not a
    /// runtime condition to tolerate.
    static func sampleTurn() -> [RelayFrame] {
        guard let data = sampleTurnJSON.data(using: .utf8),
              let frames = try? JSONDecoder().decode([RelayFrame].self, from: data) else {
            preconditionFailure("RelayFixtures.sampleTurnJSON failed to decode")
        }
        return frames
    }

    /// A single `item.completed` agentMessage frame — the minimal fixture the
    /// decode round-trip test asserts on.
    static var sampleAgentMessageJSON: String {
        """
        { "seq": 7, "sid": "3d62926c", "turn": "turn-1", "kind": "item.completed",
          "body": { "item_id": "msg-1", "type": "agentMessage", "status": "completed",
                    "ord": 3, "summary": "Answered the question",
                    "body": { "text": "Here is the answer, rendered as **markdown**." } } }
        """
    }

    /// Canonical one-turn fixture: turn.started → user prompt → reasoning →
    /// agent text (streamed) → generic tool call → file change → browser snapshot
    /// → error → usage → turn.completed, then a `snapshot` resume payload. Every
    /// `ChatItemType` and every relevant `RelayFrameKind` appears at least once.
    static let sampleTurnJSON = """
    [
      { "seq": 1, "sid": "3d62926c", "turn": "turn-1", "kind": "turn.started",
        "body": {} },

      { "seq": 2, "sid": "3d62926c", "turn": "turn-1", "kind": "item.completed",
        "body": { "item_id": "user-1", "type": "userMessage", "status": "completed",
                  "ord": 0, "summary": "Refactor the parser",
                  "body": { "text": "Refactor the parser and show me the diff." } } },

      { "seq": 3, "sid": "3d62926c", "turn": "turn-1", "kind": "item.started",
        "body": { "item_id": "reason-1", "type": "reasoning", "status": "in_progress",
                  "ord": 1, "body": { "text": "" } } },
      { "seq": 4, "sid": "3d62926c", "turn": "turn-1", "kind": "item.delta",
        "body": { "item_id": "reason-1", "patch": { "text": "Reading the parser…" } } },
      { "seq": 5, "sid": "3d62926c", "turn": "turn-1", "kind": "item.completed",
        "body": { "item_id": "reason-1", "type": "reasoning", "status": "completed",
                  "ord": 1, "body": { "text": "Reading the parser, then applying a patch." } } },

      { "seq": 6, "sid": "3d62926c", "turn": "turn-1", "kind": "item.started",
        "body": { "item_id": "msg-1", "type": "agentMessage", "status": "in_progress",
                  "ord": 2, "body": { "text": "" } } },
      { "seq": 7, "sid": "3d62926c", "turn": "turn-1", "kind": "item.delta",
        "body": { "item_id": "msg-1", "patch": { "text": "On it — " } } },
      { "seq": 8, "sid": "3d62926c", "turn": "turn-1", "kind": "item.delta",
        "body": { "item_id": "msg-1", "patch": { "text": "here is the plan." } } },

      { "seq": 9, "sid": "3d62926c", "turn": "turn-1", "kind": "item.started",
        "body": { "item_id": "tool-1", "type": "toolCall", "status": "in_progress",
                  "ord": 3, "summary": "read_file parser.swift",
                  "body": { "name": "read_file", "args": { "path": "parser.swift" } } } },
      { "seq": 10, "sid": "3d62926c", "turn": "turn-1", "kind": "item.completed",
        "body": { "item_id": "tool-1", "type": "toolCall", "status": "completed",
                  "ord": 3, "summary": "Read 220 lines",
                  "body": { "name": "read_file", "args": { "path": "parser.swift" },
                            "result": "…220 lines…", "duration_s": 0.4 } } },

      { "seq": 11, "sid": "3d62926c", "turn": "turn-1", "kind": "item.completed",
        "body": { "item_id": "file-1", "type": "fileChange", "status": "completed",
                  "ord": 4, "summary": "Patched parser.swift (+3 -1)",
                  "body": { "name": "patch", "path": "parser.swift",
                            "inline_diff": "@@ -1,1 +1,3 @@\\n-old\\n+new\\n+added" } } },

      { "seq": 12, "sid": "3d62926c", "turn": "turn-1", "kind": "item.completed",
        "body": { "item_id": "browser-1", "type": "browser", "status": "completed",
                  "ord": 5, "summary": "Snapshot of example.com",
                  "body": { "name": "browser_snapshot", "url": "https://example.com" } } },

      { "seq": 13, "sid": "3d62926c", "turn": "turn-1", "kind": "item.completed",
        "body": { "item_id": "err-1", "type": "error", "status": "failed",
                  "ord": 6, "summary": "Build failed",
                  "body": { "text": "Build failed: 2 errors in parser.swift" } } },

      { "seq": 14, "sid": "3d62926c", "turn": "turn-1", "kind": "item.completed",
        "body": { "item_id": "msg-1", "type": "agentMessage", "status": "completed",
                  "ord": 2, "summary": "Refactor complete",
                  "body": { "text": "On it — here is the plan. Done; the parser now handles the edge case." } } },

      { "seq": 15, "sid": "3d62926c", "turn": "turn-1", "kind": "item.completed",
        "body": { "item_id": "usage-1", "type": "usage", "status": "completed",
                  "ord": 7,
                  "body": { "usage": { "input": 1200, "output": 340, "total": 1540,
                                       "calls": 1, "cost_usd": 0.012,
                                       "context_used": 1540, "context_max": 128000,
                                       "context_percent": 1 } } } },

      { "seq": 16, "sid": "3d62926c", "turn": "turn-1", "kind": "turn.completed",
        "body": { "usage": { "input": 1200, "output": 340, "total": 1540 } } },

      { "seq": 17, "sid": "3d62926c", "turn": "turn-1", "kind": "snapshot",
        "body": { "cursor": 16,
                  "items": [
                    { "item_id": "user-1", "type": "userMessage", "status": "completed",
                      "ord": 0, "body": { "text": "Refactor the parser and show me the diff." } },
                    { "item_id": "msg-1", "type": "agentMessage", "status": "completed",
                      "ord": 2, "body": { "text": "Done; the parser now handles the edge case." } }
                  ] } }
    ]
    """
}
