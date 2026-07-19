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

    // MARK: - Pre-read size guard (readPickedFileData)

    /// Write `data` to a unique temp file and return its URL; the caller removes it.
    private func writeTempFile(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try data.write(to: url)
        return url
    }

    func testReadPickedFileReturnsBytesForInCapFile() throws {
        let bytes = Data("hello, files\n".utf8)
        let url = try writeTempFile(bytes, ext: "txt")
        defer { try? FileManager.default.removeItem(at: url) }

        switch AttachmentStore.readPickedFileData(at: url) {
        case .success(let read):
            XCTAssertEqual(read, bytes)
        case .failure(let message):
            XCTFail("expected bytes, got failure: \(message)")
        }
    }

    /// The core of the finding: an over-cap file must be REJECTED by the on-disk
    /// size check WITHOUT being read into memory. We prove rejection here; the
    /// "without reading" property is structural — the guard returns before the
    /// `Data(contentsOf:)` call.
    func testReadPickedFileRejectsOverCapFileWithoutReading() throws {
        // One byte over the cap. Written to disk once, but the guard must not
        // resident-load it on the attach path.
        let oversized = Data(count: AttachmentStore.maxFileAttachmentBytes + 1)
        let url = try writeTempFile(oversized, ext: "bin")
        defer { try? FileManager.default.removeItem(at: url) }

        switch AttachmentStore.readPickedFileData(at: url) {
        case .success:
            XCTFail("over-cap file should have been rejected before reading")
        case .failure(let error):
            XCTAssertTrue(
                error.message.contains("too large"),
                "unexpected rejection message: \(error.message)"
            )
        }
    }

    func testReadPickedFileAcceptsFileAtExactCap() throws {
        let atCap = Data(count: AttachmentStore.maxFileAttachmentBytes)
        let url = try writeTempFile(atCap, ext: "bin")
        defer { try? FileManager.default.removeItem(at: url) }

        switch AttachmentStore.readPickedFileData(at: url) {
        case .success(let read):
            XCTAssertEqual(read.count, AttachmentStore.maxFileAttachmentBytes)
        case .failure(let message):
            XCTFail("at-cap file should be accepted, got: \(message)")
        }
    }

    func testReadPickedFileReportsUnreadablePath() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bin")

        switch AttachmentStore.readPickedFileData(at: missing) {
        case .success:
            XCTFail("nonexistent file should not read successfully")
        case .failure(let error):
            XCTAssertTrue(error.message.contains("Couldn't read"), "unexpected message: \(error.message)")
        }
    }
}
