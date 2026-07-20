import XCTest
@testable import HermesMobile

/// W25 files-phase-1: the data-URL byte decoder behind the file viewer's
/// Share / Save to Files actions. Unlike the image decoder it must handle
/// arbitrary (non-image) binary payloads, so it is pinned directly here.
@MainActor
final class FileViewerExportTests: XCTestCase {

    func testDecodeBase64DataURLToBytes() {
        let bytes = Data([0x00, 0x10, 0x7F, 0xFF, 0x42, 0x00])
        let url = "data:application/octet-stream;base64," + bytes.base64EncodedString()
        XCTAssertEqual(FileViewerView.decodeDataURLToData(url), bytes)
    }

    func testDecodeBase64DataURLToleratesWhitespaceInPayload() {
        let bytes = Data("hello world".utf8)
        let b64 = bytes.base64EncodedString()
        let url = "data:text/plain;base64,\n" + b64 + "\n"
        XCTAssertEqual(FileViewerView.decodeDataURLToData(url), bytes)
    }

    func testDecodeNonBase64DataURL() {
        let url = "data:text/plain,hello%20there"
        XCTAssertEqual(
            FileViewerView.decodeDataURLToData(url),
            Data("hello there".utf8)
        )
    }

    func testDecodeRejectsNonDataURL() {
        XCTAssertNil(FileViewerView.decodeDataURLToData("https://example.com/x.png"))
        XCTAssertNil(FileViewerView.decodeDataURLToData("not a url"))
    }
}
