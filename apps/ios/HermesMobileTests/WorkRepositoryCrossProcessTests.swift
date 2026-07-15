import Foundation
import XCTest

final class WorkRepositoryCrossProcessTests: XCTestCase {
    func testTwoProcessLocalConnectionsEnqueueWithoutLostUpdate() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let appRepository = try WorkRepository(configuration: test.configuration)
        let extensionRepository = try WorkRepository(configuration: test.configuration)
        let scope = try workTestScope()

        async let appJob = appRepository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, text: "from app"
        ))
        async let extensionJob = extensionRepository.enqueue(WorkJobInput(
            kind: .share, scope: scope, text: "from extension"
        ))
        let inserted = try await [appJob, extensionJob]
        let jobs = try await appRepository.jobs(scope: scope)

        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(Set(jobs.map(\.jobID)), Set(inserted.map(\.jobID)))
        XCTAssertEqual(Set(jobs.compactMap(\.text)), Set(["from app", "from extension"]))
    }

    func testProtectedDataFailureIsThrownBeforeQueueing() async throws {
        let test = try makeWorkRepositoryTestConfiguration(protectedDataAvailable: { false })
        defer { try? FileManager.default.removeItem(at: test.directory) }
        XCTAssertThrowsError(try WorkRepository(configuration: test.configuration)) { error in
            XCTAssertEqual(error as? WorkRepositoryError, .protectedDataUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: test.configuration.databaseURL.path))
    }
}
