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

    @MainActor
    func testGeneratedRelayPairDeepLinkRoundTripsSpecialCharacters() {
        let payload = RelayPairingPayload(
            relayURL: "https://relay.example.test/root path?a=1&b=two",
            agentID: "agent 123/+?",
            pairingSecret: "pair secret/+=?&"
        )

        let deepLink = payload.deepLink
        let parsed = HermesURLRouter.parsePairPayload(deepLink)

        XCTAssertEqual(deepLink, "hermesapp://pair?relay=https%3A%2F%2Frelay.example.test%2Froot%20path%3Fa%3D1%26b%3Dtwo&agent=agent%20123%2F%2B%3F&pairing=pair%20secret%2F%2B%3D%3F%26&kind=relay")
        XCTAssertEqual(parsed?.relayPair?.relayURL, payload.relayURL)
        XCTAssertEqual(parsed?.relayPair?.agentID, payload.agentID)
        XCTAssertEqual(parsed?.relayPair?.pairingSecret, payload.pairingSecret)
    }

    @MainActor
    func testPairingSummaryRedactsSecretButGeneratedLinkCarriesIt() {
        let store = RelayStore(rest: RestClient(baseURL: URL(string: "http://127.0.0.1:9119")!, token: "test-token"))
        store.relayPairing = RelayPairingPayload(
            relayURL: "https://relay.example.test/root",
            agentID: "agent_123",
            pairingSecret: "supersecret456"
        )

        XCTAssertFalse(store.pairingSummary?.contains("supersecret456") ?? true)
        XCTAssertTrue(store.pairingSummary?.contains("supersec") ?? false)
        XCTAssertTrue(store.pairingDeepLink?.contains("supersecret456") ?? false)
    }

    @MainActor
    func testApplyingUnchangedRelayConfigPreservesPairingAndChangingRelayClearsIt() {
        let store = RelayStore(rest: RestClient(baseURL: URL(string: "http://127.0.0.1:9119")!, token: "test-token"))
        store.relayPairing = RelayPairingPayload(
            relayURL: "https://relay.example.test/root",
            agentID: "agent_123",
            pairingSecret: "supersecret456"
        )

        store.apply(relayConfig(url: "https://relay.example.test/root"))

        XCTAssertEqual(store.relayPairing?.pairingSecret, "supersecret456")

        store.apply(relayConfig(url: "https://relay.example.test/other"))

        XCTAssertNil(store.relayPairing)

        store.relayPairing = RelayPairingPayload(
            relayURL: "https://relay.example.test/root",
            agentID: "agent_123",
            pairingSecret: "supersecret456"
        )

        store.apply(relayConfig(url: nil))

        XCTAssertNil(store.relayPairing)
    }

    private func relayConfig(url: String?) -> RelayConfig {
        RelayConfig(json: .object([
            "relay_url": .string(url ?? ""),
            "registration_token_set": .bool(true),
            "registration_token_prefix": .string("tok"),
            "push_kinds": .array([.string("relay")]),
        ]))
    }
}

final class RelayPairingSurfaceTests: XCTestCase {
    func testRelaySettingsViewIncludesPairingTransferSurfacesAndIdentifiers() throws {
        let source = try String(contentsOfFile: relaySettingsViewPath(), encoding: .utf8)

        XCTAssertTrue(source.contains("RelayPairQRCodeView"))
        XCTAssertTrue(source.contains("ShareLink(item: pairingDeepLink)"))
        XCTAssertTrue(source.contains("UIPasteboard.general.string = pairingDeepLink"))
        XCTAssertTrue(source.contains(#""relayPairQRCode""#))
        XCTAssertTrue(source.contains(#""relayPairShareLink""#))
        XCTAssertTrue(source.contains(#""relayPairCopyLink""#))
        XCTAssertTrue(source.contains(#""relayPairLinkCopied""#))
    }

    private func relaySettingsViewPath(
        filePath: String = #filePath
    ) -> String {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Views/Settings/RelaySettingsView.swift")
            .path
    }
}
