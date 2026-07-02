import XCTest
@testable import HermesMobile

final class RelayPairPayloadTests: XCTestCase {
    @MainActor
    func testRelayPairPayloadParsesRelayAgentAndPairingSecret() {
        let payload = "hermesapp://pair?relay=https%3A%2F%2Frelay.example.test%2Froot&agent=agent_123&pairing=pair_secret_456&kind=relay"

        let parsed = HermesURLRouter.parsePairPayload(payload)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.relayPair?.relayURL, "https://relay.example.test/root")
        XCTAssertEqual(parsed?.relayPair?.agentID, "agent_123")
        XCTAssertEqual(parsed?.relayPair?.pairingSecret, "pair_secret_456")
        XCTAssertEqual(parsed?.isRelayPairing, true)
        XCTAssertEqual(parsed?.isDeviceToken, false)
        XCTAssertNil(parsed?.deviceId)
    }

    @MainActor
    func testRelayPairPayloadRejectsMissingRelayFields() {
        XCTAssertNil(HermesURLRouter.parsePairPayload("hermesapp://pair?kind=relay&agent=agent_123&pairing=pair_secret_456"))
        XCTAssertNil(HermesURLRouter.parsePairPayload("hermesapp://pair?kind=relay&relay=https%3A%2F%2Frelay.example.test&pairing=pair_secret_456"))
        XCTAssertNil(HermesURLRouter.parsePairPayload("hermesapp://pair?kind=relay&relay=https%3A%2F%2Frelay.example.test&agent=agent_123"))
    }
}
