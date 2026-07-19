import XCTest
@testable import HermesMobile

/// W25 files-phase-1: unit coverage for ``AttachmentStore``'s non-image file
/// acceptance and MIME detection — the pure, connection-free surface behind the
/// composer's "Files" attach entry (the networked `file.attach` RPC path is
/// exercised via the app; these tests pin the byte/mime contract it depends on).
@MainActor
final class AttachmentStoreFileTests: XCTestCase {

    // MARK: - MIME detection

    func testDetectedMimeTypeForKnownExtensions() {
        XCTAssertEqual(AttachmentStore.detectedMimeType(forFilename: "report.pdf"), "application/pdf")
        XCTAssertEqual(AttachmentStore.detectedMimeType(forFilename: "notes.txt"), "text/plain")
        XCTAssertEqual(AttachmentStore.detectedMimeType(forFilename: "photo.png"), "image/png")
    }

    func testDetectedMimeTypeIsCaseInsensitive() {
        XCTAssertEqual(AttachmentStore.detectedMimeType(forFilename: "REPORT.PDF"), "application/pdf")
    }

    func testDetectedMimeTypeFallsBackForUnknownOrMissingExtension() {
        XCTAssertEqual(
            AttachmentStore.detectedMimeType(forFilename: "archive.qzxq"),
            "application/octet-stream"
        )
        XCTAssertEqual(
            AttachmentStore.detectedMimeType(forFilename: "Makefile"),
            "application/octet-stream"
        )
        XCTAssertEqual(
            AttachmentStore.detectedMimeType(forFilename: ""),
            "application/octet-stream"
        )
    }

    // MARK: - data: URL encoding

    func testFileDataURLRoundTrips() {
        let bytes = Data([0x00, 0x01, 0x02, 0xFF, 0x10, 0x42])
        let url = AttachmentStore.fileDataURL(bytes, mimeType: "application/octet-stream")
        XCTAssertTrue(url.hasPrefix("data:application/octet-stream;base64,"))

        let payload = String(url.split(separator: ",", maxSplits: 1).last ?? "")
        XCTAssertEqual(Data(base64Encoded: payload), bytes)
    }

    // MARK: - Acceptance (empty / oversized guards)

    func testValidateAcceptsNonImageFileAndReturnsMime() throws {
        let csv = Data("a,b,c\n1,2,3\n".utf8)
        let mime = try AttachmentStore.validateFileAttachment(data: csv, filename: "data.csv")
        // csv resolves to a text/* type across OS versions; assert the family.
        XCTAssertTrue(mime.hasPrefix("text/"), "unexpected csv mime: \(mime)")
    }

    func testValidateAcceptsArbitraryBinaryBytes() throws {
        // Bytes that are NOT a decodable image — the old add(data:) path rejected
        // these; the file path must accept them.
        let binary = Data((0..<512).map { UInt8($0 % 256) })
        let mime = try AttachmentStore.validateFileAttachment(data: binary, filename: "blob.bin")
        XCTAssertFalse(mime.isEmpty)
    }

    func testValidateRejectsEmptyFile() {
        XCTAssertThrowsError(
            try AttachmentStore.validateFileAttachment(data: Data(), filename: "empty.txt")
        )
    }

    func testValidateRejectsOversizedFile() {
        let oversized = Data(count: AttachmentStore.maxFileAttachmentBytes + 1)
        XCTAssertThrowsError(
            try AttachmentStore.validateFileAttachment(data: oversized, filename: "huge.bin")
        )
    }

    func testValidateAcceptsFileAtExactCap() throws {
        let atCap = Data(count: AttachmentStore.maxFileAttachmentBytes)
        XCTAssertNoThrow(
            try AttachmentStore.validateFileAttachment(data: atCap, filename: "cap.bin")
        )
    }
}
