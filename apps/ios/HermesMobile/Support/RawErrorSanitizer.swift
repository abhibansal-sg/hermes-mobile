import Foundation

/// QA-3 S5/C3 — raw-error classifier, the iOS twin of the relay notifier's
/// `_humanize_raw_error` (relay/hermes_relay/notifier.py). The two implement
/// IDENTICAL rules so a push body and the in-transcript render of the same
/// failure agree word-for-word.
///
/// Why: a turn can complete carrying an upstream provider failure as its final
/// message TEXT rather than as an `error` item (owner forensics IMG_2583:
/// `HTTP 403: {"code":"unauthenticated:bad-credentials","error":"The OAuth2
/// access token could not be validated."}`). The relay now humanizes push
/// bodies at the source; this type does the same for the surfaces the phone
/// renders itself — the in-transcript `ErrorItemView` and the `RelayError`
/// descriptions that feed `ChatStore.lastError` banners (the relay's RPC error
/// frames interpolate `str(exc)` verbatim, downstream.py, so a failed RPC can
/// carry the provider's raw text). C3: no raw error codes ever reach the user;
/// one honest human line instead.
enum RawErrorSanitizer {
    /// One honest line for an auth-shaped raw failure.
    static let authLine = "Auth for this session's provider has expired — re-authentication is needed."
    /// One honest line for any other raw provider failure.
    static let genericLine = "The provider returned an error — open the session for details."

    /// `HTTP 4xx:` / `HTTP 5xx:` at the start of the line — a provider HTTP
    /// error. A SUCCESS code (`HTTP 200:`) in honest agent prose is NOT an
    /// error and never matches.
    private static let httpErrorPrefix = try! NSRegularExpression(
        pattern: #"^\s*HTTP\s+[45]\d\d\s*:"#, options: [.caseInsensitive]
    )

    private static let authHints = [
        "unauthenticated", "bad-credentials", "bad_credentials", "oauth",
        "access token", "api key", "api_key", "401", "403",
    ]

    /// Map a raw-error text to its human line, or `nil` when the text is
    /// ordinary prose (leave untouched). Two raw shapes are detected on the
    /// first non-empty line: the `HTTP 4xx/5xx:` prefix, and a bare JSON
    /// object payload (`{...}`) carrying a `"code"` or `"error"` key.
    nonisolated static func humanizeIfRawError(_ text: String?) -> String? {
        guard let text else { return nil }
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        let firstLine = stripped.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var isRaw = false
        let range = NSRange(firstLine.startIndex..., in: firstLine)
        if httpErrorPrefix.firstMatch(in: firstLine, options: [], range: range) != nil {
            isRaw = true
        } else if firstLine.hasPrefix("{"), firstLine.hasSuffix("}"),
                  firstLine.contains(#""code""#) || firstLine.contains(#""error""#) {
            isRaw = true
        }
        guard isRaw else { return nil }
        let lowered = stripped.lowercased()
        if authHints.contains(where: { lowered.contains($0) }) {
            return authLine
        }
        return genericLine
    }

    /// The text to SHOW for an error surface: the human line when the text is
    /// a raw provider error, otherwise the original text verbatim.
    nonisolated static func displayText(_ text: String) -> String {
        humanizeIfRawError(text) ?? text
    }
}
