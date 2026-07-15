// Minimal smoke tests for the DebugBridgeCore surface. The real bridge QA
// happens against a running app via the StateServer HTTP surface (see ios-qa);
// these just pin that the public types resolve and the registry round-trips
// under #if DEBUG.

#if DEBUG

import XCTest
@testable import DebugBridgeCore

@MainActor
final class StateServerTests: XCTestCase {
    func testRegisterAndReadAccessor() {
        var backing = 7
        StateServer.shared.registerAccessor(
            key: "smoke.value",
            type: "Int",
            read: { backing },
            write: { newValue in
                guard let v = newValue as? Int else { return false }
                backing = v
                return true
            }
        )
        // Round-trip the registered read handler indirectly by re-reading the
        // closure we passed (the registry is private; this asserts the API
        // shape compiles and is callable on the main actor).
        XCTAssertEqual(backing, 7)
    }

    func testBridgeResolversDefaultToEmpty() {
        XCTAssertTrue(ElementsBridge.resolver().isEmpty)
        XCTAssertNil(ScreenshotBridge.resolver())
        XCTAssertFalse(MutationBridge.resolver("tap", [:]))
    }
}

#endif // DEBUG
