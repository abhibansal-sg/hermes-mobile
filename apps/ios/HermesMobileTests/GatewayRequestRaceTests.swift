import XCTest
@testable import HermesMobile

/// R1-fix finding 1 — RPC response race in `HermesGatewayClient.requestRaw`.
///
/// The bug: the pending-request continuation was stored AFTER `task.send`, which
/// is `await`-suspendable. Because the receive loop runs on the SAME actor, a
/// fast server could deliver the response frame while `send` was suspended —
/// `resolveResponse` would then find no pending entry, drop the frame, and the
/// caller would hang until the 30s timeout fired.
///
/// The fix stores the continuation BEFORE the send. These tests force the race
/// with a mock transport that delivers the response *during* `send`, proving the
/// call now resolves with the result instead of stranding.
final class GatewayRequestRaceTests: XCTestCase {

    // MARK: - Mock transport

    /// A `GatewayWebSocketTask` whose `send` deliberately delivers the matching
    /// response frame to the in-flight receive loop *before* `send` returns,
    /// reproducing the response-before-store ordering that the bug dropped.
    private final class RaceTransport: GatewayWebSocketTask, @unchecked Sendable {

        /// Frames queued for `receive()` to hand back, in order.
        private var inbox: [URLSessionWebSocketTask.Message] = []
        /// Continuation parked by a `receive()` that ran out of queued frames.
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private let lock = NSLock()

        /// The result the server should answer the first RPC with.
        let responseResult: String

        init(responseResult: String) {
            self.responseResult = responseResult
            // The connection opens on the first `gateway.ready` event.
            enqueue(.string(
                #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready"}}"#
            ))
        }

        func resume() {}
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !inbox.isEmpty {
                    let next = inbox.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: next)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }

        /// Reproduce the race: extract the request id, queue the response, and
        /// hand it to the parked receive loop *before* yielding back from `send`.
        /// The yield lets the receive loop run while this send is still in-flight.
        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            guard case let .string(text) = message,
                  let id = Self.requestId(from: text) else { return }
            let frame = #"{"jsonrpc":"2.0","id":"\#(id)","result":{"value":"\#(responseResult)"}}"#
            enqueue(.string(frame))
            // Surrender the actor several times so the receive loop definitely
            // pumps the queued response WHILE this send is still suspended —
            // exactly the window the old store-after-send code dropped.
            for _ in 0..<5 { await Task.yield() }
        }

        private func enqueue(_ message: URLSessionWebSocketTask.Message) {
            lock.lock()
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: message)
            } else {
                inbox.append(message)
                lock.unlock()
            }
        }

        private static func requestId(from text: String) -> String? {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["id"] as? String
        }
    }

    /// A transport that opens normally (delivers `gateway.ready`) but whose `send`
    /// throws for the *first* RPC and succeeds (answering with `responseResult`)
    /// for every subsequent one. This exercises the send-failure cleanup path: the
    /// pending continuation registered BEFORE the throwing send must be removed and
    /// resumed-throwing, leaving the pending table clean so a follow-up call works.
    private final class FailingSendTransport: GatewayWebSocketTask, @unchecked Sendable {

        struct InjectedSendError: Error {}

        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private let lock = NSLock()
        private var sendCount = 0

        let responseResult: String

        init(responseResult: String) {
            self.responseResult = responseResult
            enqueue(.string(
                #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready"}}"#
            ))
        }

        func resume() {}
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !inbox.isEmpty {
                    let next = inbox.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: next)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }

        /// Throw on the first send (the pending entry is already installed by
        /// `storePending`, so the actor must fail+remove it); answer normally after.
        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            let isFirst = nextSendIsFirst()

            // Yield so the send genuinely suspends after the pending entry is
            // registered — the exact window the store-before-send fix protects.
            await Task.yield()
            if isFirst { throw InjectedSendError() }

            guard case let .string(text) = message,
                  let id = Self.requestId(from: text) else { return }
            enqueue(.string(
                #"{"jsonrpc":"2.0","id":"\#(id)","result":{"value":"\#(responseResult)"}}"#
            ))
        }

        /// Synchronous (non-async) counter bump so the `NSLock` is never held
        /// across an `await` — `NSLock.lock()` is unavailable in async contexts
        /// under Swift 6 strict concurrency.
        private func nextSendIsFirst() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            sendCount += 1
            return sendCount == 1
        }

        private func enqueue(_ message: URLSessionWebSocketTask.Message) {
            lock.lock()
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: message)
            } else {
                inbox.append(message)
                lock.unlock()
            }
        }

        private static func requestId(from text: String) -> String? {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["id"] as? String
        }
    }

    private struct Echo: Decodable, Sendable {
        let value: String
    }

    // MARK: - Tests

    /// With the response delivered mid-send, the call resolves with the result
    /// promptly (not after a timeout). A short per-call timeout makes a regression
    /// fail fast and unambiguously: the OLD code would hang the full timeout, then
    /// surface `.timeout`; the FIXED code returns the value well under it.
    func testResponseDeliveredDuringSendStillResolves() async throws {
        let transport = RaceTransport(responseResult: "raced-ok")
        let client = HermesGatewayClient { _ in transport }

        try await client.connect(baseURL: URL(string: "ws://127.0.0.1:9999")!, token: "t")

        let echo: Echo = try await client.request("ping", timeout: .seconds(2))

        XCTAssertEqual(echo.value, "raced-ok")
        await client.disconnect()
    }

    /// Tightened budget: the response is resolved in well under the time the old
    /// timeout-only recovery would have taken (30s default → here capped low).
    /// Asserting the wall-clock is small guards against a silent regression to the
    /// store-after-send ordering, where this would block ~2s before timing out.
    func testRacedResponseResolvesFastNotViaTimeout() async throws {
        let transport = RaceTransport(responseResult: "fast")
        let client = HermesGatewayClient { _ in transport }
        try await client.connect(baseURL: URL(string: "ws://127.0.0.1:9999")!, token: "t")

        let start = ContinuousClock.now
        let echo: Echo = try await client.request("ping", timeout: .seconds(5))
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(echo.value, "fast")
        // Resolved by the frame, not by the 5s timeout fallback.
        XCTAssertLessThan(elapsed, .seconds(1))
        await client.disconnect()
    }

    /// Send failure must surface as `.transport` promptly — not as a hang that
    /// only resolves when the timeout fires. With store-before-send, the pending
    /// entry is installed before `send`; `sendOrFailPending` must catch the throw
    /// and fail+remove that exact entry, so the caller fails fast under its budget.
    func testSendFailureSurfacesTransportErrorFast() async throws {
        let transport = FailingSendTransport(responseResult: "after-fail")
        let client = HermesGatewayClient { _ in transport }
        try await client.connect(baseURL: URL(string: "ws://127.0.0.1:9999")!, token: "t")

        let start = ContinuousClock.now
        do {
            let _: Echo = try await client.request("ping", timeout: .seconds(5))
            XCTFail("Expected the send failure to throw, but the call returned")
        } catch let error as GatewayError {
            // A leaked continuation would only resume via the 5s timeout (.timeout).
            // The fix resumes immediately with .transport.
            guard case .transport = error else {
                return XCTFail("Expected .transport, got \(error)")
            }
        }
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(1), "Send failure should fail fast, not via timeout")

        await client.disconnect()
    }

    /// After a failed send removes its pending entry, the pending table and actor
    /// must be uncorrupted: a follow-up RPC on the SAME client resolves normally.
    /// This proves the send-failure path leaks no continuation and does not wedge
    /// the receive loop (the second send succeeds and its response is matched).
    func testClientUsableAfterSendFailure() async throws {
        let transport = FailingSendTransport(responseResult: "recovered")
        let client = HermesGatewayClient { _ in transport }
        try await client.connect(baseURL: URL(string: "ws://127.0.0.1:9999")!, token: "t")

        do {
            let _: Echo = try await client.request("first", timeout: .seconds(5))
            XCTFail("Expected the first send to fail")
        } catch is GatewayError {
            // Expected — first send threw.
        }

        // Second call: send succeeds, response is matched against a clean table.
        let echo: Echo = try await client.request("second", timeout: .seconds(5))
        XCTAssertEqual(echo.value, "recovered")

        await client.disconnect()
    }
}
