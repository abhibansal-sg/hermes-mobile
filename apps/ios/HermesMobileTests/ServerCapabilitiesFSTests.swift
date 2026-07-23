import XCTest
@testable import HermesMobile

/// Capability-matrix coverage: one plugin-mount result owns the bundled upload,
/// file, and device features; profiles remains an independent stock probe.
@MainActor
final class ServerCapabilitiesFSTests: XCTestCase {

    func testNewFieldsDefaultUnknown() {
        let caps = ServerCapabilities()
        XCTAssertEqual(caps.fs, .unknown)
        XCTAssertEqual(caps.subagentEvents, .unknown)
    }

    func testSubagentObservedTransitionsToAvailableOnce() {
        let caps = ServerCapabilities()
        XCTAssertEqual(caps.subagentEvents, .unknown)
        caps.noteSubagentObserved()
        XCTAssertEqual(caps.subagentEvents, .available)
        // Idempotent — a second call is a no-op (no crash, stays available).
        caps.noteSubagentObserved()
        XCTAssertEqual(caps.subagentEvents, .available)
    }

    func testResetClearsNewFields() {
        let caps = ServerCapabilities()
        caps.noteSubagentObserved()
        caps.noteBroadcastObserved()
        caps.reset()
        XCTAssertEqual(caps.fs, .unknown)
        XCTAssertEqual(caps.subagentEvents, .unknown)
        XCTAssertEqual(caps.broadcast, .unknown)
    }

    func testPluginMountControlsBundledCapabilitiesWithOneProbe() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapabilityMatrixProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let rest = RestClient(
            baseURL: URL(string: "http://gateway.test")!,
            token: "t",
            session: session
        )
        let caps = ServerCapabilities()

        await caps.probe(serverURL: "http://gateway.test", rest: rest, force: true)

        XCTAssertEqual(caps.pluginMount, .available)
        XCTAssertEqual(caps.upload, .available)
        XCTAssertEqual(caps.fs, .available)
        XCTAssertEqual(caps.devices, .available)
        XCTAssertEqual(caps.profiles, .unavailable)
        XCTAssertEqual(
            Set(CapabilityMatrixProtocol.paths),
            ["/api/plugins/hermes-mobile/devices", "/api/profiles/sessions"]
        )
    }
}

private final class CapabilityMatrixProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedPaths: [String] = []

    static var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.recordedPaths.append(path)
        Self.lock.unlock()

        let status: Int
        let body: String
        if path == "/api/plugins/hermes-mobile/devices" {
            status = 200
            body = #"{"devices":[]}"#
        } else {
            status = 404
            body = #"{"detail":"not found"}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
