import Foundation
import XCTest
@testable import HermesMobile

/// Unit coverage for the ABH-305 gateway drain control (begin + cancel).
///
/// Two layers are exercised:
///   1. REST surface — `RestClient.drainGateway(action:)` must POST to
///      `/api/gateway/drain` with `{"action":"drain"|"cancel"}` and decode the
///      response into `DrainResponse` (both begin and cancel shapes).
///   2. Runner wiring — `GatewayActionRunner` must treat drain as an immediate
///      (non-pollable) action: ok → success + honest summary; ok==false →
///      explicit error (never a silent no-op); a thrown network error → an
///      explicit error state.
///
/// The existing `GatewayActionPollingTests` (in RelayStatusStoreTests.swift)
/// cover the pollable restart path; these tests cover the immediate drain path.
@MainActor
final class GatewayControlTests: XCTestCase {

    // MARK: - REST surface

    func testDrainBeginPostsCorrectPathAndBody() async throws {
        let client = stubClient(returning: #"{"ok":true,"action":"drain","requested_at":"2026-07-04T12:00:00Z","draining":true,"suppress_notification":false}"#)
        DrainStubProtocol.capturedBody = nil

        let response = try await client.drainGateway(action: .drain)

        XCTAssertEqual(DrainStubProtocol.requestedPath, "/api/gateway/drain")
        XCTAssertEqual(DrainStubProtocol.requestedMethod, "POST")
        // Body must carry action: "drain"
        let bodyString = DrainStubProtocol.capturedBody ?? ""
        XCTAssertTrue(bodyString.contains("\"action\""), "body must include action key")
        XCTAssertTrue(bodyString.contains("\"drain\""), "body action value must be drain; got \(bodyString)")

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.action, "drain")
        XCTAssertEqual(response.requestedAt, "2026-07-04T12:00:00Z")
        XCTAssertEqual(response.draining, true)
        XCTAssertEqual(response.suppressNotification, false)
    }

    func testDrainCancelPostsCorrectPathAndBody() async throws {
        let client = stubClient(returning: #"{"ok":true,"action":"cancel","was_draining":true}"#)
        DrainStubProtocol.capturedBody = nil

        let response = try await client.drainGateway(action: .cancel)

        XCTAssertEqual(DrainStubProtocol.requestedPath, "/api/gateway/drain")
        XCTAssertEqual(DrainStubProtocol.requestedMethod, "POST")
        let bodyString = DrainStubProtocol.capturedBody ?? ""
        XCTAssertTrue(bodyString.contains("\"cancel\""), "body action value must be cancel; got \(bodyString)")

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.action, "cancel")
        XCTAssertEqual(response.wasDraining, true)
    }

    func testDrainResponseDecodesOkFalseWithError() async throws {
        let client = stubClient(returning: #"{"ok":false,"error":"marker write failed","message":"disk full"}"#)

        let response = try await client.drainGateway(action: .drain)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "marker write failed")
        XCTAssertEqual(response.message, "disk full")
    }

    func testDrainResponseDecodesPartialPayloadWithoutThrowing() async throws {
        // A minimal {} payload must not throw — every field is optional.
        let client = stubClient(returning: #"{}"#)

        let response = try await client.drainGateway(action: .drain)

        XCTAssertFalse(response.ok)
        XCTAssertNil(response.action)
        XCTAssertNil(response.draining)
        XCTAssertNil(response.wasDraining)
    }

    // MARK: - Runner wiring (immediate path)

    func testDrainBeginSucceedsAndProducesHonestSummary() async {
        let runner = GatewayActionRunner(
            startAction: { _ in
                ActionResponse(ok: true, pid: nil, name: "unused", error: nil, message: nil)
            },
            startDrainAction: { action in
                XCTAssertEqual(action, .drainGateway)
                return DrainResponse(ok: true, action: "drain", requestedAt: "2026-07-04T12:00:00Z",
                                     draining: true, suppressNotification: false, wasDraining: nil,
                                     error: nil, message: nil)
            },
            fetchStatus: { _, _ in
                // Must NOT be called for an immediate action.
                XCTFail("fetchStatus must not be called for an immediate drain action")
                return ActionStatus(name: "", running: false, exitCode: 0, pid: nil, lines: [])
            },
            sleep: { _ in }
        )

        await runner.perform(.drainGateway)

        XCTAssertFalse(runner.isRunning)
        XCTAssertNil(runner.errorMessage)
        XCTAssertNil(runner.lastFailedAction)
        XCTAssertEqual(runner.progressLines, ["Drain requested — gateway is refusing new turns."])
    }

    func testCancelDrainSucceedsAndProducesHonestSummary() async {
        let runner = GatewayActionRunner(
            startAction: { _ in
                ActionResponse(ok: true, pid: nil, name: "unused", error: nil, message: nil)
            },
            startDrainAction: { action in
                XCTAssertEqual(action, .cancelDrain)
                return DrainResponse(ok: true, action: "cancel", requestedAt: nil,
                                     draining: nil, suppressNotification: nil, wasDraining: true,
                                     error: nil, message: nil)
            },
            fetchStatus: { _, _ in
                XCTFail("fetchStatus must not be called for an immediate cancel action")
                return ActionStatus(name: "", running: false, exitCode: 0, pid: nil, lines: [])
            },
            sleep: { _ in }
        )

        await runner.perform(.cancelDrain)

        XCTAssertFalse(runner.isRunning)
        XCTAssertNil(runner.errorMessage)
        XCTAssertEqual(runner.progressLines, ["Drain cancelled — gateway is resuming new turns."])
    }

    func testFailedDrainSurfacesExplicitErrorNotSilent() async {
        // ok==false from the server must produce a visible error — never a
        // silent no-op or a fake success.
        let runner = GatewayActionRunner(
            startAction: { _ in
                ActionResponse(ok: true, pid: nil, name: "unused", error: nil, message: nil)
            },
            startDrainAction: { _ in
                DrainResponse(ok: false, action: "drain", requestedAt: nil,
                              draining: nil, suppressNotification: nil, wasDraining: nil,
                              error: "marker_unchanged", message: "Gateway did not acknowledge the drain marker.")
            },
            fetchStatus: { _, _ in
                XCTFail("fetchStatus must not be called for an immediate action")
                return ActionStatus(name: "", running: false, exitCode: 0, pid: nil, lines: [])
            },
            sleep: { _ in }
        )

        await runner.perform(.drainGateway)

        XCTAssertFalse(runner.isRunning)
        XCTAssertEqual(runner.lastFailedAction, .drainGateway)
        XCTAssertEqual(runner.errorMessage, "Gateway did not acknowledge the drain marker.")
    }

    func testDrainNetworkErrorSurfacesExplicitError() async {
        // A thrown error (network failure, bad status, decoding) must surface
        // as an explicit error state, not a silent success.
        struct DrainNetworkError: LocalizedError {
            var errorDescription: String? { "Connection refused" }
        }
        let runner = GatewayActionRunner(
            startAction: { _ in
                ActionResponse(ok: true, pid: nil, name: "unused", error: nil, message: nil)
            },
            startDrainAction: { _ in
                throw DrainNetworkError()
            },
            fetchStatus: { _, _ in
                XCTFail("fetchStatus must not be called for an immediate action")
                return ActionStatus(name: "", running: false, exitCode: 0, pid: nil, lines: [])
            },
            sleep: { _ in }
        )

        await runner.perform(.drainGateway)

        XCTAssertFalse(runner.isRunning)
        XCTAssertEqual(runner.lastFailedAction, .drainGateway)
        XCTAssertEqual(runner.errorMessage, "Connection refused")
    }

    // MARK: - Enum contract

    func testRecoveryActionEnumCoversAllFourCases() {
        // The button list must include drain + cancel alongside restart + update.
        let allActions = GatewayRecoveryAction.allCases
        XCTAssertTrue(allActions.contains(.drainGateway), "drainGateway must be in allCases")
        XCTAssertTrue(allActions.contains(.cancelDrain), "cancelDrain must be in allCases")
        XCTAssertTrue(allActions.contains(.restartGateway))
        XCTAssertTrue(allActions.contains(.updateHermes))
        XCTAssertEqual(Set(allActions.map(\.id)).count, allActions.count, "ids must be unique")
    }

    func testDrainIsImmediateAndRestartIsNot() {
        // Immediate actions skip the poll loop; pollable actions enter it.
        XCTAssertTrue(GatewayRecoveryAction.drainGateway.isImmediate)
        XCTAssertTrue(GatewayRecoveryAction.cancelDrain.isImmediate)
        XCTAssertFalse(GatewayRecoveryAction.restartGateway.isImmediate)
        XCTAssertFalse(GatewayRecoveryAction.updateHermes.isImmediate)
    }

    func testDrainIsNotDestructive() {
        // Drain/cancel are reversible toggles, not destructive — they must not
        // get the red destructive tint (only restart is destructive).
        XCTAssertFalse(GatewayRecoveryAction.drainGateway.isDestructive)
        XCTAssertFalse(GatewayRecoveryAction.cancelDrain.isDestructive)
        XCTAssertTrue(GatewayRecoveryAction.restartGateway.isDestructive)
    }

    // MARK: - Helpers

    private func stubClient(returning json: String, status: Int = 200) -> RestClient {
        DrainStubProtocol.nextResponse = (json.data(using: .utf8) ?? Data(), status)
        DrainStubProtocol.requestedPath = nil
        DrainStubProtocol.requestedMethod = nil
        DrainStubProtocol.capturedBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DrainStubProtocol.self]
        return RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config),
            pathStyle: .legacy
        )
    }
}

/// Stub URLProtocol capturing the path, method, and body of drain POSTs.
/// Separate from RelayStatusStubProtocol so concurrent test classes don't
/// clobber each other's static state.
final class DrainStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var nextResponse: (data: Data, status: Int)?
    nonisolated(unsafe) static var requestedPath: String?
    nonisolated(unsafe) static var requestedMethod: String?
    nonisolated(unsafe) static var capturedBody: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedPath = request.url?.path
        Self.requestedMethod = request.httpMethod
        // URLSession.data(for:) may stream the body via httpBodyStream instead
        // of httpBody. Capture from whichever is present.
        if let body = request.httpBody {
            Self.capturedBody = String(data: body, encoding: .utf8)
        } else if let stream = request.httpBodyStream {
            Self.capturedBody = stream.readUTF8()
        }
        guard let (data, status) = Self.nextResponse else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension InputStream {
    /// Read the full stream into a UTF-8 string. Used by the stub URLProtocol
    /// to capture the request body when URLSession routes it through a stream
    /// rather than a Data blob.
    func readUTF8() -> String {
        open()
        defer { close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while hasBytesAvailable {
            let read = buffer.withUnsafeMutableBufferPointer { ptr in
                self.read(ptr.baseAddress!, maxLength: bufferSize)
            }
            if read < 0 { break }
            if read == 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
