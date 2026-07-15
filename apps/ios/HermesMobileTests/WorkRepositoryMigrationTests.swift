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

final class DraftRepositoryTests: XCTestCase {
    func testEmptyDraftIsRemovedAndContextsRestoreIndependently() async throws {
        let test = try makeWorkRepositoryTestConfiguration(); defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let scope = try workTestScope()
        _ = try await repository.saveDraft(scope: scope, contextKey: "new", storedSessionID: nil, text: "new text", cwd: "/repo", modelSelectionJSON: nil, assets: [])
        _ = try await repository.saveDraft(scope: scope, contextKey: "session-1", storedSessionID: "session-1", text: "session text", cwd: nil, modelSelectionJSON: nil, assets: [])
        let newDraft = try await repository.draft(scope: scope, contextKey: "new")
        let sessionDraft = try await repository.draft(scope: scope, contextKey: "session-1")
        XCTAssertEqual(newDraft?.draft.text, "new text")
        XCTAssertEqual(sessionDraft?.draft.text, "session text")
        _ = try await repository.saveDraft(scope: scope, contextKey: "new", storedSessionID: nil, text: "  ", cwd: nil, modelSelectionJSON: nil, assets: [])
        let removed = try await repository.draft(scope: scope, contextKey: "new")
        XCTAssertNil(removed)
    }

    func testConversionAcknowledgesOnlyMatchingRevisionAtomically() async throws {
        let test = try makeWorkRepositoryTestConfiguration(); defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let scope = try workTestScope()
        let saved = try await repository.saveDraft(scope: scope, contextKey: "new", storedSessionID: nil, text: "send me", cwd: nil, modelSelectionJSON: nil, assets: [])
        let first = try XCTUnwrap(saved)
        let job = try await repository.convertDraftToJob(draftID: first.draftID, acknowledgedRevision: first.revision)
        XCTAssertEqual(job.text, "send me")
        _ = try await repository.saveDraft(scope: scope, contextKey: "new", storedSessionID: nil, text: "later edit", cwd: nil, modelSelectionJSON: nil, assets: [])
        let retained = try await repository.draft(scope: scope, contextKey: "new")
        XCTAssertEqual(retained?.draft.text, "later edit")
        let latestSnapshot = try await repository.draft(scope: scope, contextKey: "new")
        let latest = try XCTUnwrap(latestSnapshot?.draft)
        _ = try await repository.convertDraftToJob(draftID: latest.draftID, acknowledgedRevision: latest.revision)
        let cleared = try await repository.draft(scope: scope, contextKey: "new")
        XCTAssertNil(cleared)
    }
}

final class DraftScopeIsolationTests: XCTestCase {
    func testDraftsNeverBleedAcrossServerOrProfile() async throws {
        let test = try makeWorkRepositoryTestConfiguration(); defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let a = try workTestScope(serverID: "server-a", profileID: "work")
        let b = try workTestScope(serverID: "server-b", profileID: "work")
        let c = try workTestScope(serverID: "server-a", profileID: "personal")
        _ = try await repository.saveDraft(scope: a, contextKey: "new", storedSessionID: nil, text: "only a", cwd: nil, modelSelectionJSON: nil, assets: [])
        let serverB = try await repository.draft(scope: b, contextKey: "new")
        let personal = try await repository.draft(scope: c, contextKey: "new")
        XCTAssertNil(serverB)
        XCTAssertNil(personal)
    }
}

final class ComposerDraftPersistenceTests: XCTestCase {
    func testTextCwdModelAndOrderedAttachmentsSurviveRepositoryRelaunch() async throws {
        let test = try makeWorkRepositoryTestConfiguration(); defer { try? FileManager.default.removeItem(at: test.directory) }
        let scope = try workTestScope()
        var repository: WorkRepository? = try WorkRepository(configuration: test.configuration)
        _ = try await repository?.saveDraft(scope: scope, contextKey: "new", storedSessionID: nil, text: "hello", cwd: "/repo", modelSelectionJSON: #"{"model":"m","provider":"p","fast":true}"#, assets: [
            WorkAssetInput(data: Data("one".utf8), mimeType: "image/jpeg", fileExtension: "jpg"),
            WorkAssetInput(data: Data("two".utf8), mimeType: "image/jpeg", fileExtension: "jpg"),
        ])
        repository = nil
        let relaunched = try WorkRepository(configuration: test.configuration)
        let loaded = try await relaunched.draft(scope: scope, contextKey: "new")
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.draft.text, "hello")
        XCTAssertEqual(restored.draft.cwd, "/repo")
        XCTAssertEqual(restored.assets.count, 2)
        var bytes: [Data] = []
        for asset in restored.assets { bytes.append(try await relaunched.assetData(asset)) }
        XCTAssertEqual(bytes, [Data("one".utf8), Data("two".utf8)])
    }
}
