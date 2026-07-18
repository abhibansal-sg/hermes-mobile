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

    func testUnavailableTransportLeavesPromptUnclaimedButProcessesNavigationIntent() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let prompt = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt,
            scope: harness.scope,
            text: "wait for transport",
            storedSessionID: "stored-A"
        ))
        let navigation = try await harness.repository.enqueueAppIntent(
            kind: .openSessions,
            scope: harness.scope
        )
        var localNavigationCount = 0
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { "stored-A" },
            isTransportReady: { false },
            createDestination: { _ in XCTFail("transport work must not be claimed"); throw Ambiguous() },
            resolveRuntime: { _ in XCTFail("transport work must not be resolved"); return nil },
            uploadAsset: { _, _ in XCTFail("transport work must not upload"); throw Ambiguous() },
            willSubmit: { _, _ in XCTFail("transport work must not submit") },
            submit: { _, _, _ in XCTFail("transport work must not submit"); throw Ambiguous() },
            processLocalAppIntent: { job in
                if job.intentKind == .openSessions {
                    localNavigationCount += 1
                    return true
                }
                return false
            }
        ))

        processor.wake()
        await processor.waitUntilIdleForTesting()

        let persistedPrompt = try await harness.repository.job(id: prompt.jobID)
        let persistedNavigation = try await harness.repository.job(id: navigation.jobID)
        XCTAssertEqual(persistedPrompt?.state, .queued)
        XCTAssertEqual(persistedPrompt?.attemptCount, 0,
                       "a prompt remains durable and unclaimed until readiness")
        XCTAssertNil(persistedPrompt?.leaseOwner)
        XCTAssertEqual(localNavigationCount, 1)
        XCTAssertEqual(persistedNavigation?.state, .completed,
                       "navigation intents remain local and actionable offline")
    }

    func testTransportDropDuringClaimDoesNotConsumePromptRetry() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let prompt = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt,
            scope: harness.scope,
            text: "race transport admission",
            storedSessionID: "stored-A"
        ))
        var readinessChecks = 0
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { "stored-A" },
            isTransportReady: {
                readinessChecks += 1
                return readinessChecks == 1
            },
            createDestination: { _ in XCTFail("readiness-raced prompt must not process"); throw Ambiguous() },
            resolveRuntime: { _ in XCTFail("readiness-raced prompt must not resolve"); return nil },
            uploadAsset: { _, _ in XCTFail("readiness-raced prompt must not upload"); throw Ambiguous() },
            willSubmit: { _, _ in XCTFail("readiness-raced prompt must not submit") },
            submit: { _, _, _ in XCTFail("readiness-raced prompt must not submit"); throw Ambiguous() },
            processLocalAppIntent: { _ in false }
        ))

        processor.wake()
        await processor.waitUntilIdleForTesting()

        let persisted = try await harness.repository.job(id: prompt.jobID)
        XCTAssertEqual(readinessChecks, 2)
        XCTAssertEqual(persisted?.state, .queued)
        XCTAssertEqual(persisted?.attemptCount, 0)
        XCTAssertNil(persisted?.leaseOwner)
    }
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
            isTransportReady: { true },
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
            isTransportReady: { true },
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
            isTransportReady: { true },
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
            isTransportReady: { true },
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
                isTransportReady: { true },
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
                isTransportReady: { true }, createDestination: { _ in throw Ambiguous() },
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

    /// A stock/older gateway accepts `prompt.submit` but returns only the legacy
    /// `{status: "streaming"}` payload. A completed RPC is authoritative: the
    /// absence of the optional receipt extension must not strand a delivered
    /// prompt in the outbox as indeterminate.
    func testLegacyAcceptedDispositionWithoutReceiptFieldsCompletes() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt, scope: harness.scope, text: "legacy", storedSessionID: "stored-A"
        ))
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope }, activeStoredSessionID: { "stored-A" },
            isTransportReady: { true }, createDestination: { _ in throw Ambiguous() },
            resolveRuntime: { _ in "runtime-A" }, uploadAsset: { _, _ in throw Ambiguous() },
            willSubmit: { _, _ in },
            submit: { _, _, _ in
                OutboxSubmitResult(json: .object(["status": .string("streaming")]))
            }
        ))

        processor.wake()
        await processor.waitUntilIdleForTesting()

        let persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .completed,
                       "a successful legacy submit response must not remain Pending")
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
            isTransportReady: { true }, createDestination: { _ in throw Ambiguous() },
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
            isTransportReady: { true }, createDestination: { _ in throw Ambiguous() },
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
            isTransportReady: { true },
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

    func testBackgroundWakeWaitsForForegroundResume() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt,
            scope: harness.scope,
            text: "resume me",
            storedSessionID: "stored-A"
        ))
        var submissions = 0
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { "stored-A" },
            isTransportReady: { true },
            createDestination: { _ in throw Ambiguous() },
            resolveRuntime: { _ in "runtime-A" },
            uploadAsset: { _, _ in throw Ambiguous() },
            willSubmit: { _, _ in },
            submit: { _, _, _ in
                submissions += 1
                return OutboxSubmitResult(status: "streaming", accepted: true)
            }
        ))

        await processor.suspendForBackground()
        processor.wake()
        await Task.yield()
        XCTAssertFalse(processor.isDraining)
        XCTAssertEqual(submissions, 0)

        processor.resumeFromBackground()
        await processor.waitUntilIdleForTesting()

        let persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(persisted?.state, .completed)
    }

    // MARK: - Lane C fix 1: per-session drain serialization

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// A turn streaming in session A must not stall a queued prompt for session B.
    /// The busy-session gate holds only A's own work; B drains immediately.
    func testDrainProceedsForOtherSessionWhileOneSessionStreams() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt, scope: harness.scope, text: "for-B", storedSessionID: "stored-B"
        ))
        var submitted: [String] = []
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { "stored-B" },
            isTransportReady: { true },
            // Session A is mid-turn; B is not.
            busySessionID: { "stored-A" },
            createDestination: { _ in XCTFail("existing-session job must not create"); throw Ambiguous() },
            resolveRuntime: { _ in "runtime-B" },
            uploadAsset: { _, _ in XCTFail("no assets"); throw Ambiguous() },
            willSubmit: { _, _ in },
            submit: { job, _, _ in
                submitted.append(job.clientMessageID)
                return OutboxSubmitResult(status: "streaming", accepted: true,
                                          clientMessageID: job.clientMessageID)
            }
        ))

        processor.wake(); await processor.waitUntilIdleForTesting()

        XCTAssertEqual(submitted, [job.clientMessageID], "session B drained past A's live turn")
        let persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .completed)
    }

    /// A prompt destined for the SAME session that is streaming is held — no
    /// submit, no retry spent — until that turn ends, then it drains on re-wake.
    func testSameSessionPromptWaitsForItsOwnStreamThenDrains() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt, scope: harness.scope, text: "for-A", storedSessionID: "stored-A"
        ))
        let busy = Box<String?>("stored-A")
        var submitted: [String] = []
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { "stored-A" },
            isTransportReady: { true },
            busySessionID: { busy.value },
            createDestination: { _ in throw Ambiguous() },
            resolveRuntime: { _ in "runtime-A" },
            uploadAsset: { _, _ in throw Ambiguous() },
            willSubmit: { _, _ in },
            submit: { job, _, _ in
                submitted.append(job.clientMessageID)
                return OutboxSubmitResult(status: "streaming", accepted: true,
                                          clientMessageID: job.clientMessageID)
            }
        ))

        // While A streams the prompt is held: not submitted, lease released, and
        // its retry budget untouched (a hold is not an attempt).
        processor.wake(); await processor.waitUntilIdleForTesting()
        XCTAssertTrue(submitted.isEmpty, "must not submit into the streaming session")
        var persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .queued)
        XCTAssertEqual(persisted?.attemptCount, 0, "a busy-session hold spends no retry")
        XCTAssertNil(persisted?.leaseOwner)

        // Turn ends → the session is free → the same wake path drains it.
        busy.value = nil
        processor.wake(); await processor.waitUntilIdleForTesting()
        XCTAssertEqual(submitted, [job.clientMessageID])
        persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .completed)
    }

    /// A transport-ready transition drains on the very next wake — no polling
    /// loop. A prompt held while the socket was down submits the instant
    /// readiness flips true and `wake()` is called (the existing edge-trigger).
    func testTransportReadyTransitionDrainsOnNextWake() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt, scope: harness.scope, text: "held-offline", storedSessionID: "stored-A"
        ))
        let ready = Box(false)
        var submitted: [String] = []
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { "stored-A" },
            isTransportReady: { ready.value },
            createDestination: { _ in throw Ambiguous() },
            resolveRuntime: { _ in "runtime-A" },
            uploadAsset: { _, _ in throw Ambiguous() },
            willSubmit: { _, _ in },
            submit: { job, _, _ in
                submitted.append(job.clientMessageID)
                return OutboxSubmitResult(status: "streaming", accepted: true,
                                          clientMessageID: job.clientMessageID)
            }
        ))

        // Transport down: the prompt stays durable and unclaimed.
        processor.wake(); await processor.waitUntilIdleForTesting()
        XCTAssertTrue(submitted.isEmpty)
        var persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .queued)
        XCTAssertEqual(persisted?.attemptCount, 0)

        // Readiness flips true → the next wake drains it with no intervening poll.
        ready.value = true
        processor.wake(); await processor.waitUntilIdleForTesting()
        XCTAssertEqual(submitted, [job.clientMessageID])
        persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .completed)
    }
}
