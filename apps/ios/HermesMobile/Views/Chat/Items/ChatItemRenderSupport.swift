import SwiftUI

// Wave-2 render-lane shared support (docs/RELAY-PHONE-PROTOCOL.md §2). The
// per-type item views under `Views/Chat/Items/` are thin: each reads a handful
// of fields off `ChatItem.body` and paints them in the app's existing tool-card
// visual language. This file collects the pieces every one of them shares — the
// render-only `ChatItem` body projections, the status glyph, and small
// formatting helpers — so no per-type view re-derives them and none of them
// touches the shared `ChatItem` model file (owned jointly with the client lane).

// MARK: - Render-only body projections (§2 body shapes)

extension ChatItem {
    /// A `toolCall` item's collapsed args line: the `body.args` object rendered
    /// as a compact `key: value` preview, or "" when absent. Kept distinct from
    /// the authoritative `body` so the generic card can show a one-liner without
    /// re-encoding on every layout pass.
    var argsSummary: String {
        guard let args = body["args"], !args.isNull else { return "" }
        return args.compactDescription
    }

    /// A `toolCall` item's result preview (`body.result` → `body.output`),
    /// stringified. A structured result is compacted; a plain string passes
    /// through verbatim.
    var resultPreview: String {
        guard let result = body["result"] ?? body["output"], !result.isNull else { return "" }
        return result.stringValue ?? result.compactDescription
    }

    /// A tool item's wall-clock duration in seconds (`body.duration_s` →
    /// `body.duration`), when the relay stamped one.
    var durationSeconds: Double? {
        body["duration_s"]?.doubleValue ?? body["duration"]?.doubleValue
    }

    /// The image locator for an `image` item. Mirrors the tool-path precedence in
    /// `GeneratedImageToolResult` (`host_image` → `image` → `agent_visible_image`)
    /// and additionally accepts the generic attachment/markdown-image keys the
    /// relay may carry (`url` / `source` / `path` / `data`). First non-empty wins.
    var imageReference: String? {
        for key in ["host_image", "image", "agent_visible_image", "url", "source", "path", "data"] {
            if let raw = body[key]?.stringValue {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Alt / caption text for an `image` item (`body.alt` → `body.caption` →
    /// `summary`), for the accessibility label and the caption line.
    var imageAlt: String? {
        body["alt"]?.stringValue ?? body["caption"]?.stringValue ?? summary
    }

    /// The page the `browser` item acted on (`body.url` → `body.page_url`).
    var browserURL: String? {
        body["url"]?.stringValue ?? body["page_url"]?.stringValue
    }

    /// A screenshot/snapshot locator for a `browser` item (`body.screenshot` →
    /// `body.image` → `body.snapshot`) — a remote URL or a data URL.
    var browserScreenshot: String? {
        for key in ["screenshot", "image", "snapshot"] {
            if let raw = body[key]?.stringValue {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// A short human status word for accessibility labels ("running"/"done"/"failed").
    var statusWord: String {
        switch status {
        case .inProgress: return "running"
        case .completed: return "done"
        case .failed: return "failed"
        }
    }
}

// MARK: - Image source classification

/// How a locator string should be loaded, shared by `ImageItemView` and
/// `BrowserItemView` so both classify remote/data/other references identically.
enum ItemImageSource: Equatable {
    case remote(URL)
    case dataURL(String)
    /// A reference that is neither a fetchable URL nor an inline data URL (e.g. a
    /// server-local path). Rendered as a labelled chip rather than a broken image.
    case opaque(String)

    init(reference: String) {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:") {
            self = .dataURL(trimmed)
        } else if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")),
                  let url = URL(string: trimmed) {
            self = .remote(url)
        } else {
            self = .opaque(trimmed)
        }
    }
}

// MARK: - Shared status glyph

/// The leading state glyph shared by every item card, matching `ToolActivityRow`:
/// a small spinner while in progress, a green check when completed, a red octagon
/// when failed. Extracted so all item renderers read one consistent status
/// vocabulary.
struct ChatItemStatusIcon: View {
    let status: ChatItemStatus
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        switch status {
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("In progress")
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.statusOK)
                .accessibilityLabel("Completed")
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(theme.statusError)
                .accessibilityLabel("Failed")
        }
    }
}

// MARK: - Formatting helpers

/// Pure formatting helpers for the item renderers, `nonisolated` so unit tests
/// verify them without constructing a view or entering the main actor.
enum ChatItemFormat {
    /// A compact seconds label: `0.4 → "0.4s"`, `12 → "12s"`, dropping a trailing
    /// ".0". Returns `nil` for a nil/negative duration so the caller omits the tail.
    nonisolated static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        let rounded = (seconds * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))s"
        }
        return String(format: "%.1fs", rounded)
    }
}
