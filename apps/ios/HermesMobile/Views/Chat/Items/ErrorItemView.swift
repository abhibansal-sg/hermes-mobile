import SwiftUI

/// An `error` item (docs/RELAY-PHONE-PROTOCOL.md §2) — an `error` event or a
/// failed tool. Per the contract it is NEVER hidden in a collapse: it always
/// renders its message inline, tinted with the theme's error color, on a tinted
/// error surface so a failure is impossible to miss in the transcript.
struct ErrorItemView: ChatItemContentView {
    let item: ChatItem

    @Environment(\.hermesTheme) private var theme

    init(item: ChatItem) {
        self.item = item
    }

    /// The visible message for an `error` item: the full error body when
    /// present, otherwise the one-line summary, otherwise an honest fallback.
    /// QA-3 S5/C3: a raw provider error (the upstream `HTTP 403: {"code":
    /// ...}` shape the gateway surfaces verbatim — IMG_2583) is humanized to
    /// one honest line, never shown raw — the transcript twin of the relay
    /// notifier's push sanitizer (`RawErrorSanitizer`, mirror of
    /// `_humanize_raw_error`). Pure + `nonisolated` so the contract is unit-
    /// tested without a SwiftUI view.
    nonisolated static func displayMessage(for item: ChatItem) -> String {
        let text = item.textBody
        if !text.isEmpty { return RawErrorSanitizer.displayText(text) }
        if let summary = item.summary, !summary.isEmpty {
            return RawErrorSanitizer.displayText(summary)
        }
        return "An error occurred."
    }

    private var message: String { Self.displayMessage(for: item) }

    /// A short headline shown above a multi-line body, when the summary adds
    /// context the body doesn't already start with.
    private var headline: String? {
        guard let summary = item.summary, !summary.isEmpty else { return nil }
        return summary == item.textBody ? nil : summary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(theme.statusError)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let headline {
                    Text(headline)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.statusError)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(theme.statusError)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.statusError.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.statusError.opacity(0.30), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(headline.map { "\($0). " } ?? "")\(message)")
        .accessibilityIdentifier("errorItemCard")
    }
}

#if DEBUG
#Preview("Error item") {
    VStack(alignment: .leading, spacing: 12) {
        ErrorItemView(item: ChatItem(
            itemID: "e1", type: .error, status: .failed, ord: 0,
            summary: "Build failed",
            body: ["text": "Build failed: 2 errors in parser.swift\n  parser.swift:12: expected ')'"]
        ))
        ErrorItemView(item: ChatItem(
            itemID: "e2", type: .error, status: .failed, ord: 1,
            summary: "Connection refused",
            body: .null
        ))
    }
    .padding()
}
#endif
