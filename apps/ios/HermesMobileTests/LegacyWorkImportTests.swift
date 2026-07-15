import Foundation
import XCTest

final class LegacyWorkImportTests: XCTestCase {
    func testEveryLegacySourceImportsExactlyOnceAcrossCrashAndRelaunch() async throws {
        for crashPoint in [
            LegacyImportCrashPoint.afterQueueCommit,
            .afterPendingIntentCommit,
            .afterShareCommit,
        ] {
            let test = try makeWorkRepositoryTestConfiguration()
            defer { try? FileManager.default.removeItem(at: test.directory) }
            let appSuite = "LegacyWorkImport-app-\(UUID().uuidString)"
            let sharedSuite = "LegacyWorkImport-shared-\(UUID().uuidString)"
            let appDefaults = try XCTUnwrap(UserDefaults(suiteName: appSuite))
            let sharedDefaults = try XCTUnwrap(UserDefaults(suiteName: sharedSuite))
            defer {
                appDefaults.removePersistentDomain(forName: appSuite)
                sharedDefaults.removePersistentDomain(forName: sharedSuite)
            }
            let legacyImages = test.directory.appendingPathComponent("SharedImages", isDirectory: true)
            try FileManager.default.createDirectory(at: legacyImages, withIntermediateDirectories: true)
            let imageName = "legacy.jpg"
            try Data("legacy image".utf8).write(to: legacyImages.appendingPathComponent(imageName))
            try seedLegacySources(
                appDefaults: appDefaults,
                sharedDefaults: sharedDefaults,
                imageName: imageName
            )

            let repository = try WorkRepository(configuration: test.configuration)
            do {
                try await repository.importLegacyWork(from: LegacyWorkImportSource(
                    appDefaults: appDefaults,
                    sharedDefaults: sharedDefaults,
                    sharedImagesDirectory: legacyImages,
                    scope: workTestScope(),
                    injectCrash: { point in
                        if point == crashPoint { throw InjectedCrash() }
                    }
                ))
                XCTFail("Expected injected crash at \(crashPoint)")
            } catch is InjectedCrash {
                // Relaunch below.
            }

            let relaunched = try WorkRepository(configuration: test.configuration)
            try await relaunched.importLegacyWork(from: LegacyWorkImportSource(
                appDefaults: appDefaults,
                sharedDefaults: sharedDefaults,
                sharedImagesDirectory: legacyImages,
                scope: workTestScope()
            ))
            // A second clean launch is also idempotent.
            try await relaunched.importLegacyWork(from: LegacyWorkImportSource(
                appDefaults: appDefaults,
                sharedDefaults: sharedDefaults,
                sharedImagesDirectory: legacyImages,
                scope: workTestScope()
            ))

            let jobs = try await relaunched.jobs()
            XCTAssertEqual(jobs.count, 3, "crash point: \(crashPoint)")
            XCTAssertEqual(Set(jobs.map(\.kind)), Set([.prompt, .appIntent, .share]))
            XCTAssertEqual(Set(jobs.compactMap(\.legacyImportKey)).count, 3)
            XCTAssertNil(appDefaults.object(forKey: "hermes.queue"))
            XCTAssertNil(appDefaults.object(forKey: "hermes.pendingIntentPrompt"))
            XCTAssertNil(sharedDefaults.object(forKey: "hermes.sharedInbox"))
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: legacyImages.appendingPathComponent(imageName).path),
                "legacy source image remains during the compatibility release"
            )
            let shareJob = try XCTUnwrap(jobs.first { $0.kind == .share })
            let importedAssets = try await relaunched.assets(jobID: shareJob.jobID)
            XCTAssertEqual(importedAssets.count, 1)
        }
    }

    func testQueueImportPreservesStableClientMessageIDAndSessionAffinity() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let suite = "LegacyQueueImport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let prompts = [LegacyQueueFixture(
            id: id,
            text: "queued",
            createdAt: Date(timeIntervalSince1970: 10),
            storedSessionId: "stored-session"
        )]
        defaults.set(try JSONEncoder().encode(prompts), forKey: "hermes.queue")
        let repository = try WorkRepository(configuration: test.configuration)
        try await repository.importLegacyWork(from: LegacyWorkImportSource(
            appDefaults: defaults,
            sharedDefaults: nil,
            sharedImagesDirectory: nil,
            scope: workTestScope()
        ))

        let jobs = try await repository.jobs()
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.jobID, id.uuidString.lowercased())
        XCTAssertEqual(job.clientMessageID, id.uuidString.lowercased())
        XCTAssertEqual(job.storedSessionID, "stored-session")
        XCTAssertEqual(job.createdAt, 10)
    }

    private func seedLegacySources(
        appDefaults: UserDefaults,
        sharedDefaults: UserDefaults,
        imageName: String
    ) throws {
        appDefaults.set(try JSONEncoder().encode([
            LegacyQueueFixture(
                id: UUID(),
                text: "legacy queue",
                createdAt: Date(timeIntervalSince1970: 1),
                storedSessionId: "session-1"
            ),
        ]), forKey: "hermes.queue")
        appDefaults.set(
            ["kind": "ask", "prompt": "legacy intent"],
            forKey: "hermes.pendingIntentPrompt"
        )
        sharedDefaults.set(try JSONEncoder().encode([
            LegacyShareFixture(
                id: UUID(),
                text: "legacy share",
                url: "https://example.com",
                comment: "comment",
                imageFiles: [imageName],
                createdAt: Date(timeIntervalSince1970: 2)
            ),
        ]), forKey: "hermes.sharedInbox")
    }
}

private struct InjectedCrash: Error {}

private struct LegacyQueueFixture: Encodable {
    let id: UUID
    let text: String
    let createdAt: Date
    let storedSessionId: String?
}

private struct LegacyShareFixture: Encodable {
    let id: UUID
    let text: String?
    let url: String?
    let comment: String?
    let imageFiles: [String]
    let createdAt: Date
}
