import Foundation
import XCTest
@testable import HermesMobile

final class HermesTurnAttributesTests: XCTestCase {

    func testUnixStartEpochDecodesToSwiftDateAndRoundTripsWithExplicitKey() throws {
        let epoch = 1_700_000_000.25
        let data = Data("""
        {
          "phase": "thinking",
          "toolName": null,
          "elapsedSeconds": 12,
          "needsApproval": false,
          "startedAtEpochSeconds": \(epoch)
        }
        """.utf8)

        let state = try JSONDecoder().decode(
            HermesTurnAttributes.ContentState.self,
            from: data
        )

        let decodedEpoch = try XCTUnwrap(state.startedAt?.timeIntervalSince1970)
        XCTAssertEqual(decodedEpoch, epoch, accuracy: 0.001)

        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
                as? [String: Any]
        )
        let encodedEpoch = try XCTUnwrap(encoded["startedAtEpochSeconds"] as? Double)
        XCTAssertEqual(encodedEpoch, epoch, accuracy: 0.001)
        XCTAssertNil(encoded["startedAt"], "the wire format must never use Date's reference epoch")
    }

    func testMissingStartEpochRetainsBackwardCompatibleStaticFallback() throws {
        let data = Data("""
        {
          "phase": "thinking",
          "elapsedSeconds": 12,
          "needsApproval": false
        }
        """.utf8)

        let state = try JSONDecoder().decode(
            HermesTurnAttributes.ContentState.self,
            from: data
        )

        XCTAssertNil(state.startedAt)
        XCTAssertEqual(state.elapsedSeconds, 12)
    }
}
