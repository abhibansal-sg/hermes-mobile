// B9/A5 — relay attach wire coverage (the composer "+" function, relay path).
//
// The direct attach flows talk to the IDLE gateway socket in relay mode, so
// photo/file attach rides the relay `attach` RPC instead (relay → gateway
// `file.attach` / `image.attach_bytes`, bytes inlined as a data: URL). These
// tests pin the phone side of that contract against a mock relay transport:
//
// 1. `RelaySessionCoordinator.attach` emits the ratified wire shape
//    (`kind` + `data_url` required, `session_id` optional, `name` omitted when
//    empty) and adopts the session id the relay resolved;
// 2. `AttachmentStore.attachFile` (the Files-picker path) routes through the
//    relay — NOT `connection.client` — when the transport is `.relay`, and
//    parses the gateway-shaped result identically to the direct path;
// 3. `AttachmentStore.uploadAndAttach` (the photo/camera path) routes each
//    pending image through the relay as inlined base64 and drains `pending`
//    per-item, exactly like the direct upload loop.
//
// The wire shape asserted here is the same one tests/e2e_daily_driver/test_h
// drives through the REAL relay + gateway end-to-end.

import XCTest
import UIKit
@testable import HermesMobile

@MainActor
final class RelayAttachWireTests: XCTestCase {

    // MARK: - In-process mock relay transport (mirrors RelaySessionCoordinatorTests)

    /// Minimal fake relay: records upstream frames; an optional script answers.
    final class MockRelayTransport: RelayTransport, @unchecked Sendable {
        struct Upstream { let method: String; let id: String?; let params: [String: Any] }

        private let lock = NSLock()
        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var sent: [Upstream] = []
        private var cancelled = false

        var script: (@Sendable (Upstream, MockRelayTransport) -> Void)?

        init(script: (@Sendable (Upstream, MockRelayTransport) -> Void)? = nil) { self.script = script }

        func resume() {}

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock(); continuation.resume(throwing: URLError(.cancelled))
                } else if !inbox.isEmpty {
                    let next = inbox.removeFirst(); lock.unlock(); continuation.resume(returning: next)
                } else {
                    waiter = continuation; lock.unlock()
                }
            }
        }

        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            guard case let .string(text) = message, let upstream = Self.parse(text) else { return }
            record(upstream)   // sync helper: NSLock is unavailable directly in an async context
            script?(upstream, self)
        }

        private func record(_ upstream: Upstream) {
            lock.lock(); defer { lock.unlock() }
            sent.append(upstream)
        }

        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            lock.lock(); cancelled = true; let parked = waiter; waiter = nil; lock.unlock()
            parked?.resume(throwing: URLError(.cancelled))
        }

        func deliver(_ text: String) {
            lock.lock()
            if let parked = waiter {
                waiter = nil; lock.unlock(); parked.resume(returning: .string(text))
            } else {
                inbox.append(.string(text)); lock.unlock()
            }
        }

        func deliverResult(id: String, result: JSONValue) {
            let payload: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .string(id), "result": result,
            ])
            guard let data = try? JSONEncoder().encode(payload) else { return }
            deliver(String(decoding: data, as: UTF8.self))
        }

        func upstreams() -> [Upstream] { lock.lock(); defer { lock.unlock() }; return sent }

        private static func parse(_ text: String) -> Upstream? {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return nil }
            return Upstream(method: method, id: object["id"] as? String,
                            params: object["params"] as? [String: Any] ?? [:])
        }
    }

    private let url = URL(string: "ws://127.0.0.1:9999/relay")!

    /// A script that answers `attach` with a gateway-shaped result (the relay
    /// merges `session_id` + `kind` into the gateway result).
    private static let attachResponder: @Sendable (MockRelayTransport.Upstream, MockRelayTransport) -> Void = { upstream, relay in
        guard let id = upstream.id, upstream.method == "attach" else { return }
        let kind = upstream.params["kind"] as? String ?? ""
        let name = upstream.params["name"] as? String ?? ""
        if kind == "file" {
            relay.deliverResult(id: id, result: .object([
                "session_id": .string("sess-77"),
                "kind": .string("file"),
                "attached": .bool(true),
                "name": .string(name),
                "path": .string("/gw/.hermes/desktop-attachments/\(name)"),
                "ref_path": .string(name),
                "ref_text": .string("@file:\(name)"),
                "uploaded": .bool(true),
            ]))
        } else {
            relay.deliverResult(id: id, result: .object([
                "session_id": .string("sess-77"),
                "kind": .string("image"),
                "attached": .bool(true),
                "path": .string("/gw/images/upload_1.jpg"),
                "count": .number(1),
            ]))
        }
    }

    // MARK: - (1) Coordinator wire shape

    func testCoordinatorAttachEmitsRatifiedWireShapeAndAdoptsSession() async throws {
        let transport = MockRelayTransport(script: Self.attachResponder)
        let coordinator = RelaySessionCoordinator(
            chatStore: ChatStore(),
            clientFactory: { RelayClient { _ in transport } }
        )
        try await coordinator.start(url: url)

        let result = try await coordinator.attach(
            sessionID: "s1", kind: "file", name: "report.pdf",
            dataURL: "data:application/pdf;base64,QUJD"
        )

        XCTAssertEqual(result["ref_text"]?.stringValue, "@file:report.pdf")
        // The resolved session id is adopted so a follow-up submit(sessionID:
        // nil) lands on the SAME session (new-chat image-first send).
        XCTAssertEqual(coordinator.activeSessionID, "sess-77")

        let frame = transport.upstreams().first { $0.method == "attach" }
        XCTAssertNotNil(frame, "no attach frame hit the relay wire")
        XCTAssertEqual(frame?.params["session_id"] as? String, "s1")
        XCTAssertEqual(frame?.params["kind"] as? String, "file")
        XCTAssertEqual(frame?.params["name"] as? String, "report.pdf")
        XCTAssertEqual(frame?.params["data_url"] as? String, "data:application/pdf;base64,QUJD")

        await coordinator.stop()
    }

    func testCoordinatorAttachOmitsAbsentSessionAndEmptyName() async throws {
        let transport = MockRelayTransport(script: Self.attachResponder)
        let coordinator = RelaySessionCoordinator(
            chatStore: ChatStore(),
            clientFactory: { RelayClient { _ in transport } }
        )
        try await coordinator.start(url: url)

        // New chat: no stored session, nothing driven yet — session_id must be
        // ABSENT on the wire so the relay creates + owns one (SUBMIT parity),
        // and an empty name must not ride along.
        _ = try await coordinator.attach(kind: "image", name: "", dataURL: "data:image/jpeg;base64,xx")

        let frame = transport.upstreams().first { $0.method == "attach" }
        XCTAssertNotNil(frame)
        XCTAssertNil(frame?.params["session_id"], "absent session must not send an empty id")
        XCTAssertNil(frame?.params["name"], "empty name must be omitted")
        XCTAssertEqual(coordinator.activeSessionID, "sess-77")

        await coordinator.stop()
    }

    // MARK: - (2) Files-picker path routes through the relay

    /// Pin the persisted transport path for `body`, restoring prior state.
    private func withRelayTransport(_ body: () async throws -> Void) async throws {
        let key = DefaultsKeys.transportPath
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: key)
        try await body()
    }

    func testAttachFileRoutesThroughRelayInRelayMode() async throws {
        try await withRelayTransport {
            let transport = MockRelayTransport(script: Self.attachResponder)
            let connection = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())
            connection.relayCoordinatorFactory = {
                RelaySessionCoordinator(
                    chatStore: ChatStore(),
                    clientFactory: { RelayClient { _ in transport } }
                )
            }
            let coordinator = connection.ensureRelayCoordinator()
            try await coordinator.start(url: url)

            let store = AttachmentStore()
            let result = try await store.attachFile(
                data: Data("hermes attach payload".utf8),
                filename: "notes.txt",
                sessionId: "s1",
                connection: connection
            )

            // The gateway-shaped result parses IDENTICALLY to the direct path.
            XCTAssertEqual(result.refText, "@file:notes.txt")
            XCTAssertEqual(result.refPath, "notes.txt")
            XCTAssertEqual(result.name, "notes.txt")
            XCTAssertTrue(result.path.hasSuffix("/notes.txt"))

            // And it rode the relay wire — NOT the idle gateway client.
            let frame = transport.upstreams().first { $0.method == "attach" }
            XCTAssertNotNil(frame, "file attach must go over the relay in relay mode")
            XCTAssertEqual(frame?.params["kind"] as? String, "file")
            XCTAssertEqual(frame?.params["session_id"] as? String, "s1")
            let dataURL = frame?.params["data_url"] as? String ?? ""
            XCTAssertTrue(dataURL.hasPrefix("data:text/plain;base64,"))
        }
    }

    // MARK: - (3) Photo path routes through the relay

    func testUploadAndAttachRoutesImagesThroughRelayInRelayMode() async throws {
        try await withRelayTransport {
            let transport = MockRelayTransport(script: Self.attachResponder)
            let connection = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())
            connection.relayCoordinatorFactory = {
                RelaySessionCoordinator(
                    chatStore: ChatStore(),
                    clientFactory: { RelayClient { _ in transport } }
                )
            }
            let coordinator = connection.ensureRelayCoordinator()
            try await coordinator.start(url: url)

            // One tiny decodable image through the same normalisation the
            // photo picker uses (add(data:) → JPEG ≤ 2048px).
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
            let png = renderer.pngData { ctx in
                UIColor.systemRed.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
            let store = AttachmentStore()
            XCTAssertTrue(store.add(data: png))
            XCTAssertEqual(store.pending.count, 1)

            let paths = try await store.uploadAndAttach(sessionId: "s1", connection: connection)

            XCTAssertEqual(paths, ["/gw/images/upload_1.jpg"])
            XCTAssertTrue(store.pending.isEmpty, "a successful relay attach drains the pending item")

            let frame = transport.upstreams().first { $0.method == "attach" }
            XCTAssertNotNil(frame, "photo attach must go over the relay in relay mode")
            XCTAssertEqual(frame?.params["kind"] as? String, "image")
            XCTAssertEqual(frame?.params["session_id"] as? String, "s1")
            let dataURL = frame?.params["data_url"] as? String ?? ""
            XCTAssertTrue(
                dataURL.hasPrefix("data:image/jpeg;base64,"),
                "the normalised JPEG must ride inlined: \(dataURL.prefix(40))"
            )
        }
    }
}
