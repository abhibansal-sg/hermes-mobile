import XCTest
@testable import HermesMobile

/// QA-3 S5/C3 — the iOS twin of the relay notifier's `_humanize_raw_error`
/// (relay/tests/test_notifier.py pins the Python half; the two must agree
/// word-for-word). Owner forensics IMG_2583: a turn completed carrying the
/// upstream provider's OAuth failure verbatim (`HTTP 403: {"code":
/// "unauthenticated:bad-credentials",...}`) — raw error codes must never
/// reach a user surface (push body, in-transcript error card, lastError
/// banner).
final class RawErrorSanitizerTests: XCTestCase {

    private static let rawAuth403 =
        "HTTP 403: {\"code\":\"unauthenticated:bad-credentials\","
        + "\"error\":\"The OAuth2 access token could not be validated.\"}"

    // MARK: - Raw shapes → human lines

    func testHTTP403AuthErrorHumanizedToAuthLine() {
        XCTAssertEqual(
            RawErrorSanitizer.humanizeIfRawError(Self.rawAuth403),
            RawErrorSanitizer.authLine
        )
        // the human line carries none of the raw payload
        let human = RawErrorSanitizer.displayText(Self.rawAuth403)
        for needle in ["HTTP 403", "unauthenticated", "bad-credentials", "{", "OAuth2"] {
            XCTAssertFalse(human.contains(needle), "raw fragment leaked: \(needle)")
        }
    }

    func testHTTP401AndGenericHTTP5xx() {
        XCTAssertEqual(
            RawErrorSanitizer.humanizeIfRawError("HTTP 401: unauthorized"),
            RawErrorSanitizer.authLine
        )
        XCTAssertEqual(
            RawErrorSanitizer.humanizeIfRawError("HTTP 502: bad gateway"),
            RawErrorSanitizer.genericLine
        )
    }

    func testBareJSONErrorPayloadHumanized() {
        XCTAssertEqual(
            RawErrorSanitizer.humanizeIfRawError(#"{"code":"rate_limited","error":"quota exceeded"}"#),
            RawErrorSanitizer.genericLine
        )
    }

    // MARK: - Ordinary prose is NEVER touched (false-positive guard)

    func testSuccessStatusProseUntouched() {
        let prose = "The endpoint returned HTTP 200: OK, so the smoke test passed."
        XCTAssertNil(RawErrorSanitizer.humanizeIfRawError(prose))
        XCTAssertEqual(RawErrorSanitizer.displayText(prose), prose)
    }

    func testBraceMentioningProseUntouched() {
        let prose = #"The config looked like {"model": "qwen"} and worked fine"#
        XCTAssertNil(RawErrorSanitizer.humanizeIfRawError(prose))
    }

    func testEmptyAndNil() {
        XCTAssertNil(RawErrorSanitizer.humanizeIfRawError(nil))
        XCTAssertNil(RawErrorSanitizer.humanizeIfRawError(""))
        XCTAssertNil(RawErrorSanitizer.humanizeIfRawError("   \n  "))
    }

    // MARK: - Consumer seams (C3 audit of the relay-flow alert paths)

    func testRelayErrorRPCRawMessageHumanized() {
        // The relay's RPC error frames interpolate str(exc) (downstream.py) —
        // a provider failure rides the message into lastError banners.
        let error = RelayError.rpc(code: -32000, message: Self.rawAuth403)
        XCTAssertEqual(error.errorDescription, RawErrorSanitizer.authLine)
    }

    func testRelayErrorRPCNumericCodeNeverSurfaces() {
        // Non-raw messages keep their text but drop the raw JSON-RPC code.
        let error = RelayError.rpc(code: -32000, message: "session is busy")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("session is busy"))
        XCTAssertFalse(desc.contains("-32000"), "C3: no raw error codes to the user")
    }

    func testErrorItemViewShowsHumanLineNotRawPayload() {
        let item = ChatItem(
            itemID: "e1", type: .error, status: .failed, ord: 0,
            body: ["text": Self.rawAuth403]
        )
        let shown = ErrorItemView.displayMessage(for: item)
        XCTAssertEqual(shown, RawErrorSanitizer.authLine)
        XCTAssertFalse(shown.contains("HTTP 403"))
        XCTAssertFalse(shown.contains("{"))
        // an honest error message is untouched
        let human = ChatItem(
            itemID: "e2", type: .error, status: .failed, ord: 1,
            summary: "Build failed", body: ["text": "2 errors in parser.swift"]
        )
        XCTAssertEqual(ErrorItemView.displayMessage(for: human), "2 errors in parser.swift")
    }
}
