import XCTest
@testable import HermesMobile

/// Decode coverage for the F4A-A1 file endpoints' response models
/// (`FSListResult`, `FSReadResult`, `PathCompletionItem`) and the RestClient FS
/// error mapping (`mapFSError` → `FSReadError`). Decoding goes through the same
/// `.useDefaultKeys` path `RestClient.fsList`/`fsRead` use (the models declare
/// explicit snake_case `CodingKeys`).
final class FileSystemModelTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - /api/fs/list

    func testListResultDecodesEntriesDirsFirstShape() throws {
        let json = """
        {"root":"/Users/abc/proj","path":"src","entries":[
          {"name":"lib","is_dir":true,"size":0,"modified":1700000000.0},
          {"name":"main.swift","is_dir":false,"size":2048,"modified":1700000123.5}
        ],"truncated":false}
        """
        let result = try decode(FSListResult.self, json)
        XCTAssertEqual(result.root, "/Users/abc/proj")
        XCTAssertEqual(result.path, "src")
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.entries[0].isDir)
        XCTAssertEqual(result.entries[0].size, 0)
        XCTAssertFalse(result.entries[1].isDir)
        XCTAssertEqual(result.entries[1].size, 2048)
        XCTAssertEqual(result.entries[1].modified, 1700000123.5)
        XCTAssertFalse(result.truncated)
    }

    func testListResultTruncatedFlag() throws {
        let json = """
        {"root":"/r","path":"","entries":[],"truncated":true}
        """
        let result = try decode(FSListResult.self, json)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testListEntryTolerantOfMissingModified() throws {
        let json = """
        {"root":"/r","path":"","entries":[{"name":"x","is_dir":false,"size":1}],"truncated":false}
        """
        let result = try decode(FSListResult.self, json)
        XCTAssertEqual(result.entries.first?.name, "x")
        XCTAssertNil(result.entries.first?.modified)
    }

    // MARK: - /api/fs/read

    func testReadResultUTF8WithTruncation() throws {
        let json = """
        {"path":"a.txt","size":1500000,"encoding":"utf-8","content":"hello","truncated":true}
        """
        let result = try decode(FSReadResult.self, json)
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertFalse(result.isBinary)
        XCTAssertEqual(result.content, "hello")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.size, 1500000)
        XCTAssertNil(result.dataURL)
    }

    func testReadResultBinaryHasNullContent() throws {
        let json = """
        {"path":"logo.png","size":4096,"encoding":"binary","content":null}
        """
        let result = try decode(FSReadResult.self, json)
        XCTAssertEqual(result.encoding, .binary)
        XCTAssertTrue(result.isBinary)
        XCTAssertNil(result.content)
        XCTAssertFalse(result.truncated)
    }

    func testReadResultDecodesDataURL() throws {
        let json = """
        {"path":"img.png","size":512,"encoding":"binary","content":null,"truncated":false,
         "data_url":"data:image/png;base64,abc123"}
        """
        let result = try decode(FSReadResult.self, json)
        XCTAssertEqual(result.dataURL, "data:image/png;base64,abc123")
        XCTAssertTrue(result.isImage)
    }

    func testReadResultDataURLAbsentWhenNotProvided() throws {
        let json = """
        {"path":"file.txt","size":10,"encoding":"utf-8","content":"hello","truncated":false}
        """
        let result = try decode(FSReadResult.self, json)
        XCTAssertNil(result.dataURL)
    }

    // MARK: - isImage detection

    func testIsImageForKnownImageExtensions() {
        let imageExts = ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "tif"]
        for ext in imageExts {
            let r = FSReadResult(path: "photo.\(ext)", size: 0, encoding: .binary, content: nil, truncated: false)
            XCTAssertTrue(r.isImage, "Expected isImage for .\(ext)")
        }
    }

    func testIsImageFalseForNonImageExtensions() {
        let nonImage = ["swift", "txt", "json", "pdf", "zip", "md"]
        for ext in nonImage {
            let r = FSReadResult(path: "file.\(ext)", size: 0, encoding: .utf8, content: "x", truncated: false)
            XCTAssertFalse(r.isImage, "Expected !isImage for .\(ext)")
        }
    }

    // MARK: - complete.path items

    func testPathCompletionItemDecodeAndLabel() throws {
        let json = """
        {"text":"src/main.swift","display":"main.swift","meta":"file"}
        """
        let item = try decode(PathCompletionItem.self, json)
        XCTAssertEqual(item.text, "src/main.swift")
        XCTAssertEqual(item.label, "main.swift")
        XCTAssertFalse(item.isDirectory)
    }

    func testPathCompletionItemDirectoryFromMeta() throws {
        let item = try decode(PathCompletionItem.self, #"{"text":"src","display":null,"meta":"dir"}"#)
        XCTAssertTrue(item.isDirectory)
        // No display → label falls back to text.
        XCTAssertEqual(item.label, "src")
    }

    func testPathCompletionItemDirectoryFromTrailingSlash() throws {
        let item = try decode(PathCompletionItem.self, #"{"text":"nested/","display":null,"meta":null}"#)
        XCTAssertTrue(item.isDirectory)
    }

    func testMentionPickerParseDropsEmptyText() {
        let raw: JSONValue = .object(["items": .array([
            .object(["text": .string("a.txt")]),
            .object(["text": .string("")]),
            .object(["display": .string("no text")])
        ])])
        let items = MentionPicker.parse(raw)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.text, "a.txt")
    }

    func testMentionPickerParseEmptyWhenNoItems() {
        XCTAssertTrue(MentionPicker.parse(.object([:])).isEmpty)
        XCTAssertTrue(MentionPicker.parse(.null).isEmpty)
    }

    // MARK: - Error mapping

    func testMapFSErrorTooLargeParsesSize() {
        let mapped = RestClient.mapFSError(.badStatus(413, body: #"{"error":"file too large","size":2097152}"#))
        guard case .tooLarge(let size) = mapped else {
            return XCTFail("expected .tooLarge, got \(mapped)")
        }
        XCTAssertEqual(size, 2_097_152)
        // Audit finding: description includes the formatted size.
        let desc = mapped.errorDescription ?? ""
        XCTAssertTrue(desc.contains("Too large"), "description should mention 'Too large', got: \(desc)")
        XCTAssertTrue(desc.contains("2") || desc.contains("MB"), "description should include size info, got: \(desc)")
    }

    func testMapFSErrorTooLargeNoSizeStillDescribes() {
        let mapped = RestClient.mapFSError(.badStatus(413, body: #"{"error":"file too large"}"#))
        guard case .tooLarge(let size) = mapped else {
            return XCTFail("expected .tooLarge, got \(mapped)")
        }
        XCTAssertNil(size)
        XCTAssertEqual(mapped.errorDescription, "Too large to preview")
    }

    func testMapFSErrorEscape403() {
        let mapped = RestClient.mapFSError(.badStatus(403, body: #"{"error":"path escapes session root"}"#))
        guard case .pathEscapesRoot = mapped else {
            return XCTFail("expected .pathEscapesRoot, got \(mapped)")
        }
    }

    func testMapFSErrorNotAFile404() {
        let mapped = RestClient.mapFSError(.badStatus(404, body: #"{"error":"not a file"}"#))
        guard case .notAFile = mapped else {
            return XCTFail("expected .notAFile, got \(mapped)")
        }
    }

    func testMapFSErrorNotADirectory404IsStillNotAFile() {
        // A real path miss (not the unknown-session marker) stays .notAFile.
        let mapped = RestClient.mapFSError(.badStatus(404, body: #"{"error":"not a directory"}"#))
        guard case .notAFile = mapped else {
            return XCTFail("expected .notAFile, got \(mapped)")
        }
    }

    func testMapFSErrorUnknownSession404IsNoActiveSession() {
        // R1-fix finding 2: the server's unknown/stale-sid 404 carries
        // `{"error":"unknown session"}` and must surface as "No Active Session"
        // (the browser handles it gracefully instead of "file not found").
        let mapped = RestClient.mapFSError(.badStatus(404, body: #"{"error":"unknown session"}"#))
        guard case .noActiveSession = mapped else {
            return XCTFail("expected .noActiveSession, got \(mapped)")
        }
        XCTAssertEqual(mapped.errorDescription, "No Active Session")
    }

    func testMapFSErrorOtherPassesThrough() {
        let mapped = RestClient.mapFSError(.badStatus(401, body: "unauthorized"))
        guard case .other = mapped else {
            return XCTFail("expected .other, got \(mapped)")
        }
    }

    // MARK: - tooLarge description includes size

    func testTooLargeDescriptionWithSize() {
        let error = FSReadError.tooLarge(size: 2_097_152)
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.hasPrefix("Too large to preview"), "got: \(desc)")
        // Should include a formatted size: ByteCountFormatter for 2 MB gives "2 MB".
        XCTAssertTrue(desc.contains("MB") || desc.contains("2"), "should contain size info, got: \(desc)")
    }

    func testTooLargeDescriptionWithoutSize() {
        let error = FSReadError.tooLarge(size: nil)
        XCTAssertEqual(error.errorDescription, "Too large to preview")
    }

    // MARK: - Query building

    func testFSQueryOmitsEmptyPath() {
        let q = RestClient.fsQuery(sessionId: "sess-1", path: nil)
        XCTAssertEqual(q, "session_id=sess-1")
        let q2 = RestClient.fsQuery(sessionId: "sess-1", path: "")
        XCTAssertEqual(q2, "session_id=sess-1")
    }

    func testFSQueryEncodesPath() {
        let q = RestClient.fsQuery(sessionId: "s", path: "a dir/b.txt")
        XCTAssertTrue(q.contains("session_id=s"))
        XCTAssertTrue(q.contains("path="))
        // The space must be percent-encoded.
        XCTAssertTrue(q.contains("a%20dir") || q.contains("a%2520dir"))
        XCTAssertFalse(q.contains("a dir"))
    }

    // MARK: - /api/logs model + query building (ABH-368)

    func testLogResultDecodesFileAndLines() throws {
        let json = #"{"file":"agent","lines":["2026-07-04 01:00:00 INFO agent: started","line2"]}"#
        let result = try decode(SystemLogResult.self, json)
        XCTAssertEqual(result.file, "agent")
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0], "2026-07-04 01:00:00 INFO agent: started")
    }

    func testLogResultEmptyLinesArray() throws {
        // A file that exists but has no content → 200 with lines: [] (NOT an error)
        let json = #"{"file":"desktop","lines":[]}"#
        let result = try decode(SystemLogResult.self, json)
        XCTAssertEqual(result.file, "desktop")
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testLogResultTolerantOfMissingKeys() throws {
        // Defensive: if the server omits a key, decode should not throw.
        let result = try decode(SystemLogResult.self, "{}")
        XCTAssertEqual(result.file, "")
        XCTAssertTrue(result.lines.isEmpty)
    }

    // MARK: - Query building (logsQuery)

    func testLogsQueryIncludesFileAndLines() {
        let q = RestClient.logsQuery(
            file: "agent", level: .all, search: "", lineCount: 200
        )
        XCTAssertTrue(q.contains("file=agent"))
        XCTAssertTrue(q.contains("lines=200"))
        // Level=all should NOT include a level param (server treats absent as no filter)
        XCTAssertFalse(q.contains("level="))
        // Empty search should NOT include a search param
        XCTAssertFalse(q.contains("search="))
    }

    func testLogsQueryIncludesLevelWhenNotAll() {
        let q = RestClient.logsQuery(
            file: "errors", level: .warning, search: "", lineCount: 100
        )
        XCTAssertTrue(q.contains("file=errors"))
        XCTAssertTrue(q.contains("level=WARNING"))
        XCTAssertFalse(q.contains("search="))
    }

    func testLogsQueryIncludesSearchWhenNonEmpty() {
        let q = RestClient.logsQuery(
            file: "agent", level: .all, search: "timeout", lineCount: 200
        )
        XCTAssertTrue(q.contains("search=timeout"))
    }

    func testLogsQueryPercentEncodesSearch() {
        let q = RestClient.logsQuery(
            file: "agent", level: .all, search: "connection refused", lineCount: 200
        )
        // Spaces must be encoded so the query string is valid
        XCTAssertTrue(q.contains("search=connection") && q.contains("refused"))
        XCTAssertFalse(q.contains("connection refused"))
    }

    // MARK: - Error mapping (mapLogsError)

    func testMapLogsError400IsUnknownFile() {
        let body = #"{"detail":"Unknown log file: foo"}"#
        let error = RestClient.mapLogsError(.badStatus(400, body: body))
        if case .unknownFile(let detail) = error {
            XCTAssertEqual(detail, "Unknown log file: foo")
        } else {
            XCTFail("expected .unknownFile, got: \(error)")
        }
    }

    func testMapLogsError400TolerantOfMalformedBody() {
        let error = RestClient.mapLogsError(.badStatus(400, body: "garbage"))
        if case .unknownFile(let detail) = error {
            // Falls back to the raw body when detail can't be parsed
            XCTAssertEqual(detail, "garbage")
        } else {
            XCTFail("expected .unknownFile, got: \(error)")
        }
    }

    func testMapLogsError500IsOther() {
        let error = RestClient.mapLogsError(.badStatus(500, body: "oops"))
        if case .other = error {
            // pass
        } else {
            XCTFail("expected .other, got: \(error)")
        }
    }

    func testMapLogsErrorNetworkIsOther() {
        let error = RestClient.mapLogsError(.network("timeout"))
        if case .other(let msg) = error {
            XCTAssertTrue(msg.contains("timeout") || msg.contains("Network"))
        } else {
            XCTFail("expected .other, got: \(error)")
        }
    }

    // MARK: - Level extraction (extractLogLevel)

    func testExtractLogLevelDebug() {
        XCTAssertEqual(extractLogLevel("2026-01-01 00:00:00 DEBUG module: msg"), .debug)
    }

    func testExtractLogLevelInfo() {
        XCTAssertEqual(extractLogLevel("2026-01-01 00:00:00 INFO module: msg"), .info)
    }

    func testExtractLogLevelWarning() {
        XCTAssertEqual(extractLogLevel("2026-01-01 00:00:00 WARNING module: msg"), .warning)
    }

    func testExtractLogLevelError() {
        XCTAssertEqual(extractLogLevel("2026-01-01 00:00:00 ERROR module: msg"), .error)
    }

    func testExtractLogLevelCritical() {
        XCTAssertEqual(extractLogLevel("2026-01-01 00:00:00 CRITICAL module: msg"), .error)
    }

    func testExtractLogLevelNilForUnrecognizable() {
        XCTAssertNil(extractLogLevel("a line with no level token"))
    }

    // MARK: - SystemLogLevel enum

    func testLevelAllIsNotLevel() {
        XCTAssertFalse(SystemLogLevel.all.isLevel)
    }

    func testLevelRealAreLevels() {
        XCTAssertTrue(SystemLogLevel.debug.isLevel)
        XCTAssertTrue(SystemLogLevel.info.isLevel)
        XCTAssertTrue(SystemLogLevel.warning.isLevel)
        XCTAssertTrue(SystemLogLevel.error.isLevel)
    }

    func testLevelRawValues() {
        XCTAssertEqual(SystemLogLevel.debug.rawValue, "DEBUG")
        XCTAssertEqual(SystemLogLevel.info.rawValue, "INFO")
        XCTAssertEqual(SystemLogLevel.warning.rawValue, "WARNING")
        XCTAssertEqual(SystemLogLevel.error.rawValue, "ERROR")
    }
}
