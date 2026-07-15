import XCTest
import GRDB
@testable import HermesMobile

final class TransferManagerStateMachineTests: XCTestCase {
    func testMissingUploadFileIsRejectedBeforeRowOrTaskCreation() async throws {
        let repository = try TransferRepository(testDB: DatabaseQueue())
        let manager = TransferManager(repository: repository,
                                      sessionIdentifier: "test.missing.\(UUID().uuidString)")
        do {
            _ = try await manager.enqueueUpload(
                file: URL(fileURLWithPath: "/definitely/missing"),
                to: URL(string: "https://example.invalid")!
            )
            XCTFail("Expected missing file")
        } catch TransferError.missingFile {}
        let active = try await repository.activeRecords()
        XCTAssertTrue(active.isEmpty)
    }

    func testCancelTransitionsDurableTaskToCancelled() async throws {
        let repository = try TransferRepository(testDB: DatabaseQueue())
        let manager = TransferManager(repository: repository,
                                      sessionIdentifier: "test.cancel.\(UUID().uuidString)")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 1, count: 1024).write(to: file)
        let record = try await manager.enqueueUpload(
            file: file, to: URL(string: "https://example.invalid/upload")!
        )
        await manager.cancel(id: record.id)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let current = try await repository.record(id: record.id)
            if current?.state == .cancelled { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Cancellation was not persisted")
    }
}
