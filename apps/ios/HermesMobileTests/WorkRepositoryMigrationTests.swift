import Foundation
import GRDB
import XCTest

final class WorkRepositoryMigrationTests: XCTestCase {
    func testSchemaMatchesDurabilityContract() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)

        let database = try DatabasePool(path: test.configuration.databaseURL.path)
        let tables = try await database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }
        XCTAssertTrue(Set(["drafts", "work_jobs", "work_assets", "job_assets", "draft_assets", "transfers"])
            .isSubset(of: Set(tables)))

        let jobColumns = try await database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(work_jobs)")
                .map { $0["name"] as String }
        }
        XCTAssertTrue(jobColumns.contains("server_id"))
        XCTAssertTrue(jobColumns.contains("profile_id"))
        XCTAssertTrue(jobColumns.contains("client_message_id"))
        XCTAssertFalse(jobColumns.contains { $0.localizedCaseInsensitiveContains("token") })
        XCTAssertFalse(jobColumns.contains { $0.localizedCaseInsensitiveContains("credential") })
        XCTAssertFalse(jobColumns.contains { $0.localizedCaseInsensitiveContains("absolute") })

        let pragmas = try await repository.databasePragmas()
        XCTAssertEqual(pragmas.journalMode.lowercased(), "wal")
        XCTAssertTrue(pragmas.foreignKeysEnabled)
        XCTAssertEqual(pragmas.busyTimeoutMilliseconds, 5_000)
    }

    @MainActor
    func testObservationPublishesOnMainActorWithoutOwningDatabase() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(
            configuration: test.configuration,
            observation: observation
        )
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt,
            scope: workTestScope(),
            text: "observe me"
        ))
        XCTAssertEqual(observation.snapshot.jobs.map(\.text), ["observe me"])
    }

    func testAssetPathIsRelativeAndDatabaseContainsNoCredential() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let job = try await repository.enqueue(
            WorkJobInput(kind: .share, scope: nil, text: "share"),
            assets: [WorkAssetInput(
                data: Data("image".utf8),
                mimeType: "image/jpeg",
                fileExtension: "jpg"
            )]
        )
        let asset = try await repository.assets(jobID: job.jobID).first
        let relativePath = try XCTUnwrap(asset?.relativePath)
        XCTAssertFalse(relativePath.hasPrefix("/"))
        XCTAssertFalse(relativePath.contains(test.directory.path))

        let bytes = try Data(contentsOf: test.configuration.databaseURL)
        let databaseText = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(databaseText.contains("secret-bearer-token"))
        XCTAssertFalse(databaseText.contains(test.directory.path))
    }
}
