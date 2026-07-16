import XCTest
#if !OUTBOX_STANDALONE_TESTS
@testable import HermesMobile
#endif

@MainActor
final class OutboxProcessorTests: XCTestCase {
    private struct Harness {
        let repository: WorkRepository
        let observation: WorkRepositoryObservation
        let scope: WorkScope
        let directory: URL
    }

    private func makeHarness() throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxProcessor-\(UUID().uuidString)", isDirectory: true)
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory),
            observation: observation
        )
        return Harness(
            repository: repository,
            observation: observation,
            scope: try WorkScope(serverID: "https://gateway.test", profileID: "default"),
            directory: directory
        )
    }

    private struct Ambiguous: Error {}

    func testAmbiguousRetryReusesClientIDAndDoesNotCreateAnotherJob() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt, scope: harness.scope, text: "once", storedSessionID: "stored-A"
        ))
        var submittedIDs: [String] = []
        var shouldFail = true
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { "stored-A" },
            canProcessPrompt: { true },
            createDestination: { _ in XCTFail("existing-session job must not create"); throw Ambiguous() },
            resolveRuntime: { _ in "runtime-A" },
            uploadAsset: { _, _ in XCTFail("no assets"); throw Ambiguous() },
            willSubmit: { _, _ in },
            submit: { submitted, _, _ in
                submittedIDs.append(submitted.clientMessageID)
                if shouldFail { shouldFail = false; throw Ambiguous() }
                return OutboxSubmitResult(
                    status: "streaming", accepted: true,
                    clientMessageID: submitted.clientMessageID
                )
            }
        ))

        processor.wake(); await processor.waitUntilIdleForTesting()
        var retained = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(retained?.state, .submitting)
        XCTAssertEqual(retained?.lastErrorCode, "transport_ambiguous")

        processor.wake(); await processor.waitUntilIdleForTesting()
        retained = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(retained?.state, .completed)
        XCTAssertEqual(submittedIDs, [job.clientMessageID, job.clientMessageID])
        let allJobs = try await harness.repository.jobs()
        XCTAssertEqual(allJobs.count, 1)
    }

    func testNewSessionDestinationIsPersistedAndReusedAcrossRetry() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt,
            scope: harness.scope,
            intentKind: .newSession,
            text: "new chat"
        ))
        var activeStored: String?
        var createCount = 0
        var failOnce = true
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { activeStored },
            canProcessPrompt: { true },
            createDestination: { _ in
                createCount += 1
                activeStored = "stored-created"
                return OutboxDestination(runtimeSessionID: "runtime-created", storedSessionID: "stored-created")
            },
            resolveRuntime: { stored in stored == "stored-created" ? "runtime-created" : nil },
            uploadAsset: { _, _ in throw Ambiguous() },
            willSubmit: { _, _ in },
            submit: { submitted, _, _ in
                if failOnce { failOnce = false; throw Ambiguous() }
                return OutboxSubmitResult(status: "streaming", accepted: true,
                                          clientMessageID: submitted.clientMessageID)
            }
        ))

        processor.wake(); await processor.waitUntilIdleForTesting()
        var persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.destinationSessionID, "stored-created")
        processor.wake(); await processor.waitUntilIdleForTesting()

        XCTAssertEqual(createCount, 1)
        persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .completed)
    }

    func testAskIntentCreatesOneStableDestinationThenProcessesLocalNavigation() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let ask = try await harness.repository.enqueueAppIntent(
            kind: .askHermes, text: "durable ask", scope: harness.scope
        )
        let navigation = try await harness.repository.enqueueAppIntent(
            kind: .openSessions, scope: harness.scope
        )
        var createCount = 0
        var localCount = 0
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope }, activeStoredSessionID: { nil },
            canProcessPrompt: { true },
            createDestination: { _ in
                createCount += 1
                return OutboxDestination(runtimeSessionID: "runtime-intent", storedSessionID: "stored-intent")
            },
            resolveRuntime: { stored in stored == "stored-intent" ? "runtime-intent" : nil },
            uploadAsset: { _, _ in throw Ambiguous() },
            willSubmit: { _, _ in },
            submit: { submitted, _, _ in
                OutboxSubmitResult(
                    status: "streaming", accepted: true,
                    clientMessageID: submitted.clientMessageID
                )
            },
            processLocalAppIntent: { job in
                if job.intentKind == .openSessions {
                    localCount += 1
                    return true
                }
                return false
            }
        ))

        processor.wake(); await processor.waitUntilIdleForTesting()

        let completedAsk = try await harness.repository.job(id: ask.jobID)
        let completedNavigation = try await harness.repository.job(id: navigation.jobID)
        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(localCount, 1)
        XCTAssertEqual(completedAsk?.destinationSessionID, "stored-intent")
        XCTAssertEqual(completedAsk?.state, .completed)
        XCTAssertEqual(completedNavigation?.state, .completed)
    }

    func testShareRetryReusesDestinationUploadedAssetAndClientID() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueueShare(
            WorkJobInput(kind: .share, scope: harness.scope, text: "photo"),
            assets: [WorkAssetInput(data: Data("jpeg".utf8), mimeType: "image/jpeg", fileExtension: "jpg")]
        )
        var createCount = 0
        var uploadCount = 0
        var submittedIDs: [String] = []
        var failOnce = true
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { nil },
            canProcessPrompt: { true },
            createDestination: { _ in
                createCount += 1
                return OutboxDestination(runtimeSessionID: "runtime-share", storedSessionID: "stored-share")
            },
            resolveRuntime: { stored in stored == "stored-share" ? "runtime-share" : nil },
            uploadAsset: { _, _ in
                uploadCount += 1
                return OutboxUploadedAsset(transferID: "transfer-share", remotePath: "/remote/share.jpg")
            },
            willSubmit: { _, _ in },
            submit: { submitted, _, _ in
                submittedIDs.append(submitted.clientMessageID)
                if failOnce { failOnce = false; throw Ambiguous() }
                return OutboxSubmitResult(
                    status: "streaming",
                    accepted: true,
                    clientMessageID: submitted.clientMessageID
                )
            }
        ))

        processor.wake(); await processor.waitUntilIdleForTesting()
        var persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.destinationSessionID, "stored-share")
        XCTAssertEqual(persisted?.state, .submitting)

        processor.wake(); await processor.waitUntilIdleForTesting()
        persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .completed)
        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(submittedIDs, [job.clientMessageID, job.clientMessageID])
    }

    func testPromptRemainsVisibleForInProgressAndIndeterminate() async throws {
        for status in ["in_progress", "indeterminate"] {
            let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
            let job = try await harness.repository.enqueue(WorkJobInput(
                kind: .prompt, scope: harness.scope, text: status, storedSessionID: "stored-A"
            ))
            let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
                currentScope: { harness.scope }, activeStoredSessionID: { "stored-A" },
                canProcessPrompt: { true },
                createDestination: { _ in throw Ambiguous() },
                resolveRuntime: { _ in "runtime-A" },
                uploadAsset: { _, _ in throw Ambiguous() },
                willSubmit: { _, _ in },
                submit: { submitted, _, _ in
                    OutboxSubmitResult(status: status, accepted: false,
                                       clientMessageID: submitted.clientMessageID)
                }
            ))
            processor.wake(); await processor.waitUntilIdleForTesting()
            let retained = try await harness.repository.job(id: job.jobID)
            XCTAssertEqual(retained?.state, .submitting)
            XCTAssertEqual(retained?.lastErrorCode, status)
        }
    }

    func testAllAcceptedDispositionsCompleteWithoutWaitingForAssistant() async throws {
        for disposition in ["streaming", "queued", "steered"] {
            let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
            let job = try await harness.repository.enqueue(WorkJobInput(
                kind: .prompt, scope: harness.scope, text: disposition, storedSessionID: "stored-A"
            ))
            let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
                currentScope: { harness.scope }, activeStoredSessionID: { "stored-A" },
                canProcessPrompt: { true }, createDestination: { _ in throw Ambiguous() },
                resolveRuntime: { _ in "runtime-A" }, uploadAsset: { _, _ in throw Ambiguous() },
                willSubmit: { _, _ in },
                submit: { submitted, _, _ in
                    OutboxSubmitResult(status: disposition, accepted: true,
                                       clientMessageID: submitted.clientMessageID)
                }
            ))
            processor.wake(); await processor.waitUntilIdleForTesting()
            let persisted = try await harness.repository.job(id: job.jobID)
            XCTAssertEqual(persisted?.state, .completed)
        }
    }

    func testAttachmentRetryResumesAfterLastUploadedAsset() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(
            WorkJobInput(kind: .prompt, scope: harness.scope, text: "images", storedSessionID: "stored-A"),
            assets: [
                WorkAssetInput(data: Data("one".utf8), mimeType: "image/jpeg", fileExtension: "jpg"),
                WorkAssetInput(data: Data("two".utf8), mimeType: "image/jpeg", fileExtension: "jpg"),
            ]
        )
        var uploadCounts: [Int: Int] = [:]
        var failSecondOnce = true
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope }, activeStoredSessionID: { "stored-A" },
            canProcessPrompt: { true }, createDestination: { _ in throw Ambiguous() },
            resolveRuntime: { _ in "runtime-A" },
            uploadAsset: { _, snapshot in
                uploadCounts[snapshot.link.ordinal, default: 0] += 1
                if snapshot.link.ordinal == 1, failSecondOnce {
                    failSecondOnce = false
                    throw Ambiguous()
                }
                return OutboxUploadedAsset(
                    transferID: "transfer-\(snapshot.link.ordinal)",
                    remotePath: "/remote/\(snapshot.link.ordinal).jpg"
                )
            },
            willSubmit: { _, _ in },
            submit: { submitted, _, _ in
                OutboxSubmitResult(status: "streaming", accepted: true,
                                   clientMessageID: submitted.clientMessageID)
            }
        ))

        processor.wake(); await processor.waitUntilIdleForTesting()
        var persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .retryWait)
        processor.wake(); await processor.waitUntilIdleForTesting()

        XCTAssertEqual(uploadCounts[0], 1)
        XCTAssertEqual(uploadCounts[1], 2)
        persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .completed)
    }

    func testConcurrentWakeSourcesNeverOverlapDrains() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt, scope: harness.scope, text: "wake", storedSessionID: "stored-A"
        ))
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope }, activeStoredSessionID: { "stored-A" },
            canProcessPrompt: { true }, createDestination: { _ in throw Ambiguous() },
            resolveRuntime: { _ in "runtime-A" }, uploadAsset: { _, _ in throw Ambiguous() },
            willSubmit: { _, _ in },
            submit: { submitted, _, _ in
                try? await Task.sleep(for: .milliseconds(40))
                return OutboxSubmitResult(status: "streaming", accepted: true,
                                          clientMessageID: submitted.clientMessageID)
            }
        ))

        processor.wake(); processor.wake(); processor.wake()
        await processor.waitUntilIdleForTesting()

        XCTAssertEqual(processor.maximumConcurrentDrains, 1)
        let persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .completed)
    }

    func testBackgroundSuspendReleasesLeaseAtDurableStage() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt,
            scope: harness.scope,
            text: "background me",
            storedSessionID: "stored-A"
        ))
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { "stored-A" },
            canProcessPrompt: { true },
            createDestination: { _ in throw Ambiguous() },
            resolveRuntime: { _ in "runtime-A" },
            uploadAsset: { _, _ in throw Ambiguous() },
            willSubmit: { _, _ in },
            submit: { _, _, _ in
                try await Task.sleep(for: .seconds(30))
                return OutboxSubmitResult(status: "streaming", accepted: true)
            }
        ))

        processor.wake()
        for _ in 0..<100 {
            if try await harness.repository.job(id: job.jobID)?.leaseOwner != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await processor.suspendForBackground()

        let persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .submitting)
        XCTAssertNil(persisted?.leaseOwner)
        XCTAssertNil(persisted?.leaseExpiresAt)
    }
}
