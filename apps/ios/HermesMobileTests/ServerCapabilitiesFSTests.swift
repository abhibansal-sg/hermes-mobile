import XCTest
@testable import HermesMobile

/// F4A-A1 coverage for the `fs` (eager) + `subagentEvents` (passive) capability
/// fields added to `ServerCapabilities`. The eager `fs` probe needs a live HTTP
/// round-trip (exercised by the integration gate + `RestClient` decode tests);
/// here we pin the STATE-MACHINE invariants that don't need a server: the
/// default tri-state, the passive setters' idempotent transitions, and that
/// `reset()` clears both new fields back to `.unknown`.
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

    func testProbeFsResultMapping() async {
        // The probe shapes its result as the shared UploadProbeResult tri-state;
        // assert each arm maps to the right capability State the same way the
        // upload probe does (the switch lives in ServerCapabilities.probeFs, but
        // its mapping is the contract: available→available, unavailable→
        // unavailable, inconclusive→unknown). We verify the RestClient probe
        // classifies an unroutable host as inconclusive (never throws).
        let rest = RestClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,   // nothing listening
            token: "t"
        )
        let result = await rest.probeFsEndpoint()
        // A connection refused / transport failure must classify as inconclusive,
        // never throw — so a flaky network leaves `fs` at `.unknown` (optimistic).
        XCTAssertEqual(result, .inconclusive)
    }
}
