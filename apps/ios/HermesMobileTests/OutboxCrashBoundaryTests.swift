import XCTest
#if !OUTBOX_STANDALONE_TESTS
@testable import HermesMobile
#endif

@MainActor
final class OutboxCrashBoundaryTests: XCTestCase {
    private struct BoundaryError: Error {}

    func testRelaunchResumesEveryDurablePromptBoundary() async throws {
        for boundary in [
            WorkJobState.queued,
            .creatingDestination,
            .uploading,
            .submitting,
            .accepted,
            .retryWait,
        ] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OutboxBoundary-\(boundary.rawValue)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let configuration = WorkRepositoryConfiguration(containerURL: directory)
            let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
            var repository: WorkRepository? = try WorkRepository(configuration: configuration)
            let needsNewDestination = boundary == .creatingDestination
            let job = try await repository!.enqueue(
                WorkJobInput(
                    kind: .prompt,
                    scope: scope,
                    intentKind: needsNewDestination ? .newSession : nil,
                    text: boundary.rawValue,
                    storedSessionID: needsNewDestination ? nil : "stored-A"
                ),
                assets: boundary == .uploading
                    ? [WorkAssetInput(data: Data("asset".utf8), mimeType: "image/jpeg", fileExtension: "jpg")]
                    : []
            )
            switch boundary {
            case .queued:
                break
            case .creatingDestination:
                _ = try await repository!.transitionJob(
                    id: job.jobID, from: .queued, to: .creatingDestination
                )
            case .uploading:
                _ = try await repository!.transitionJob(
                    id: job.jobID, from: .queued, to: .uploading,
                    destinationSessionID: "stored-A"
                )
            case .submitting:
                _ = try await repository!.transitionJob(
                    id: job.jobID, from: .queued, to: .submitting,
                    destinationSessionID: "stored-A"
                )
            case .accepted:
                _ = try await repository!.transitionJob(
                    id: job.jobID, from: .queued, to: .submitting,
                    destinationSessionID: "stored-A"
                )
                _ = try await repository!.transitionJob(
                    id: job.jobID, from: .submitting, to: .accepted
                )
            case .retryWait:
                _ = try await repository!.transitionJob(
                    id: job.jobID, from: .queued, to: .retryWait
                )
            default:
                XCTFail("unexpected boundary")
            }

            // Simulate force termination: discard the first repository actor and
            // open a fresh DatabasePool over the same protected files.
            repository = nil
            let relaunched = try WorkRepository(configuration: configuration)
            var activeStored: String? = needsNewDestination ? nil : "stored-A"
            var createdDestinations = 0
            let processor = OutboxProcessor(repository: relaunched, dependencies: .init(
                currentScope: { scope }, activeStoredSessionID: { activeStored },
                isTransportReady: { true },
                createDestination: { _ in
                    createdDestinations += 1
                    activeStored = "stored-created"
                    return OutboxDestination(
                        runtimeSessionID: "runtime-created", storedSessionID: "stored-created"
                    )
                },
                resolveRuntime: { stored in
                    ["stored-A", "stored-created"].contains(stored) ? "runtime-A" : nil
                },
                uploadAsset: { _, snapshot in
                    OutboxUploadedAsset(
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

            let persisted = try await relaunched.job(id: job.jobID)
            XCTAssertEqual(persisted?.state, .completed, "failed relaunch boundary: \(boundary)")
            XCTAssertNotNil(persisted?.destinationSessionID)
            XCTAssertEqual(createdDestinations, needsNewDestination ? 1 : 0)
        }
    }
}
