import CryptoKit
import GRDB
import UserNotifications
import XCTest
@testable import HermesMobile

final class RelayV2CryptoFixtureTests: XCTestCase {
    func testHubTypedErrorPreservesCodeAndRetryAfter() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayV2HubErrorStub.self]
        RelayV2HubErrorStub.status = 429
        RelayV2HubErrorStub.headers = ["Retry-After": "7", "Content-Type": "application/json"]
        RelayV2HubErrorStub.body = Data("{\"error\":{\"code\":\"RATE_LIMITED\",\"message\":\"slow down\"}}".utf8)
        let hub = RelayV2HubTransport(
            configuration: try RelayV2HubConfiguration(
                baseURL: URL(string: "https://relay.example.test")!,
                routeID: "rte_device", routeSigningPrivateKey: Data(repeating: 1, count: 32)
            ),
            session: URLSession(configuration: configuration)
        )
        let envelope = try RelayV2OuterEnvelope(
            header: RelayV2OuterHeader(
                source: "rte_device", destination: "rte_agent",
                messageID: RelayV2Wire.base64URL(Data(repeating: 1, count: 16)),
                messageClass: .control, expiresAtMilliseconds: 9_999_999_999_999,
                recipientKeyGeneration: 1
            ),
            encapsulatedKey: Data(repeating: 2, count: 32),
            ciphertext: Data(repeating: 3, count: 16), signature: Data(repeating: 4, count: 64)
        )
        do {
            _ = try await hub.post(envelope)
            XCTFail("Expected typed rate limit")
        } catch let error as RelayV2ProtocolError {
            guard case .remote(.rateLimited, let retryAfter) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(retryAfter, 7)
        }
    }

    func testPairingQRIsExactRawJSONAndRejectsURLWrapping() throws {
        let key = RelayV2Wire.base64URL(Data(repeating: 7, count: 32))
        let payload = """
        {"v":2,"hub":"https://relay.example.test","relay_route":"rte_agent","offer_route":"off_route","offer_id":"ofr_test","offer_transport_token":"\(key)","expires_at_ms":9999999999999,"relay_kem_pub":"\(key)","relay_sign_pub":"\(key)","pair_secret":"\(key)"}
        """
        let offer = try RelayV2PairingOffer.decodeScannerPayload(payload)
        XCTAssertEqual(offer.offerID, "ofr_test")
        XCTAssertThrowsError(try RelayV2PairingOffer.decodeScannerPayload(
            "hermesapp://pair?offer=\(payload)"
        ))
        XCTAssertThrowsError(try RelayV2PairingOffer.decodeScannerPayload(
            payload.dropLast() + ",\"extra\":true}"
        ))
    }

    func testHubWaitingMailboxFixtureIsAcceptedOnlyForExactOffer() async throws {
        let key = RelayV2Wire.base64URL(Data(repeating: 7, count: 32))
        let payload = """
        {"v":2,"hub":"https://relay.example.test","relay_route":"rte_agent","offer_route":"off_route","offer_id":"ofr_test","offer_transport_token":"\(key)","expires_at_ms":9999999999999,"relay_kem_pub":"\(key)","relay_sign_pub":"\(key)","pair_secret":"\(key)"}
        """
        let offer = try RelayV2PairingOffer.decodeScannerPayload(payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayV2PairingStub.self]
        let transport = RelayV2HTTPPairingTransport(
            session: URLSession(configuration: configuration)
        )
        RelayV2PairingStub.body = Data("{\"status\":\"waiting\",\"offer_id\":\"ofr_test\"}".utf8)
        let waiting = try await transport.fetchPairAccept(offer: offer)
        XCTAssertNil(waiting)
        RelayV2PairingStub.body = Data("{\"status\":\"waiting\",\"offer_id\":\"ofr_attacker\"}".utf8)
        await XCTAssertThrowsErrorAsync {
            _ = try await transport.fetchPairAccept(offer: offer)
        }
    }

    func testHubConfigurationRejectsRemotePlaintext() throws {
        XCTAssertThrowsError(try RelayV2HubConfiguration(
            baseURL: XCTUnwrap(URL(string: "http://relay.example.test")),
            routeID: "device_test",
            routeSigningPrivateKey: Data(repeating: 1, count: 32)
        ))
        XCTAssertNoThrow(try RelayV2HubConfiguration(
            baseURL: XCTUnwrap(URL(string: "https://relay.example.test")),
            routeID: "device_test",
            routeSigningPrivateKey: Data(repeating: 1, count: 32)
        ))
    }

    func testPushRegistrationTranscriptMatchesPythonContract() throws {
        let transcript = RelayV2PushRegistrationClient.registrationTranscript(
            challenge: "challenge_test",
            apnsToken: String(repeating: "ab", count: 32),
            bundleID: "ai.hermes.app",
            environment: "sandbox",
            previewKEMPublicKey: "preview_key_test",
            installationNonce: "nonce_test",
            operation: "endpoint-register",
            hubRouteID: "rte_test"
        )
        XCTAssertEqual(
            transcript.map { String(format: "%02x", $0) }.joined(),
            "485047324154544553540000000e6368616c6c656e67655f7465737400000020271a413bd339c5709fdceaec41f14f11e9fbfb5042d72d331c65f32b284cd09a0000000d61692e6865726d65732e6170700000000773616e64626f7800000010707265766965775f6b65795f746573740000000a6e6f6e63655f7465737400000011656e64706f696e742d7265676973746572000000087274655f74657374"
        )
    }

    private struct AuthFixture: Decodable {
        let aadHex: String
        let canonicalEnvelopeSHA256Hex: String
        let canonicalInnerJSON: String
        let innerMessage: RelayV2SecureMessage
        let outerEnvelope: RelayV2OuterEnvelope
        let recipientPrivateKeyHex: String
        let senderPublicKeyHex: String
        let signingPublicKeyHex: String
        let signaturePayloadSHA256Hex: String

        enum CodingKeys: String, CodingKey {
            case aadHex = "aad_hex"
            case canonicalEnvelopeSHA256Hex = "canonical_envelope_sha256_hex"
            case canonicalInnerJSON = "canonical_inner_json"
            case innerMessage = "inner_message"
            case outerEnvelope = "outer_envelope"
            case recipientPrivateKeyHex = "recipient_private_key_hex"
            case senderPublicKeyHex = "sender_public_key_hex"
            case signingPublicKeyHex = "signing_public_key_hex"
            case signaturePayloadSHA256Hex = "signature_payload_sha256_hex"
        }
    }

    private struct NotificationFixture: Decodable {
        let aadHex: String
        let canonicalDescriptorSHA256Hex: String
        let canonicalPreviewJSON: String
        let descriptor: RelayV2NotificationDescriptor
        let recipientPrivateKeyHex: String
        let senderPublicKeyHex: String

        enum CodingKeys: String, CodingKey {
            case aadHex = "aad_hex"
            case canonicalDescriptorSHA256Hex = "canonical_descriptor_sha256_hex"
            case canonicalPreviewJSON = "canonical_preview_json"
            case descriptor
            case recipientPrivateKeyHex = "recipient_private_key_hex"
            case senderPublicKeyHex = "sender_public_key_hex"
        }
    }

    func testSharedAuthenticatedEnvelopeFixture() throws {
        let fixture: AuthFixture = try loadFixture("auth-envelope")
        let envelope = fixture.outerEnvelope
        XCTAssertEqual(envelope.header.authenticatedData.hex, fixture.aadHex)
        XCTAssertEqual(
            Data(SHA256.hash(data: try envelope.canonicalJSON())).hex,
            fixture.canonicalEnvelopeSHA256Hex
        )
        XCTAssertEqual(
            Data(SHA256.hash(data: envelope.header.signaturePayload(
                encapsulatedKey: envelope.encapsulatedKey,
                ciphertext: envelope.ciphertext
            ))).hex,
            fixture.signaturePayloadSHA256Hex
        )
        let inner = try RelayV2Crypto.openAuthenticatedEnvelope(
            envelope,
            recipientPrivateKeys: [3: try Data(hex: fixture.recipientPrivateKeyHex)],
            senderAgreementPublicKey: try Data(hex: fixture.senderPublicKeyHex),
            senderSigningPublicKey: try Data(hex: fixture.signingPublicKeyHex),
            expectedSenderKeyGeneration: fixture.innerMessage.senderKeyGeneration,
            purpose: .chat,
            direction: .agentToDevice,
            receive: RelayV2ReceiveContext(
                expectedDestination: "rte_device_fixture",
                expectedSource: "rte_agent_fixture",
                nowMilliseconds: 1_784_449_950_000,
                seenMessageIDs: []
            )
        )
        XCTAssertEqual(String(decoding: try inner.canonicalJSON(), as: UTF8.self), fixture.canonicalInnerJSON)

        var tampered = try JSONSerialization.jsonObject(with: envelope.canonicalJSON()) as! [String: Any]
        tampered["dst"] = "rte_attacker"
        let tamperedData = try JSONSerialization.data(withJSONObject: tampered, options: [.sortedKeys])
        let tamperedEnvelope = try RelayV2OuterEnvelope.decodeStrict(from: tamperedData)
        XCTAssertThrowsError(try RelayV2Crypto.openAuthenticatedEnvelope(
            tamperedEnvelope,
            recipientPrivateKeys: [3: try Data(hex: fixture.recipientPrivateKeyHex)],
            senderAgreementPublicKey: try Data(hex: fixture.senderPublicKeyHex),
            senderSigningPublicKey: try Data(hex: fixture.signingPublicKeyHex),
            expectedSenderKeyGeneration: fixture.innerMessage.senderKeyGeneration,
            purpose: .chat,
            direction: .agentToDevice,
            receive: RelayV2ReceiveContext(
                expectedDestination: "rte_device_fixture", expectedSource: "rte_agent_fixture",
                nowMilliseconds: 1_784_449_950_000, seenMessageIDs: []
            )
        ))
    }

    func testSharedNotificationFixtureDecryptsOffline() throws {
        let fixture: NotificationFixture = try loadFixture("notification-preview")
        XCTAssertEqual(fixture.descriptor.authenticatedData.hex, fixture.aadHex)
        XCTAssertEqual(
            Data(SHA256.hash(data: try RelayV2Wire.canonicalJSON(fixture.descriptor))).hex,
            fixture.canonicalDescriptorSHA256Hex
        )
        let preview = try RelayV2Crypto.decryptNotificationPreview(
            descriptor: fixture.descriptor,
            recipientPrivateKey: try Data(hex: fixture.recipientPrivateKeyHex),
            senderAgreementPublicKey: try Data(hex: fixture.senderPublicKeyHex),
            nowMilliseconds: 1_784_449_950_000
        )
        XCTAssertEqual(String(decoding: try preview.canonicalJSON(), as: UTF8.self), fixture.canonicalPreviewJSON)
        XCTAssertEqual(preview.category, "HERMES_APPROVAL")
        XCTAssertEqual(preview.action?["request_id"]?.stringValue, "req_fixture")
    }

    func testNotificationServiceProcessorEntrypointFallbackAndCategoryPolicy() throws {
        let fixture: NotificationFixture = try loadFixture("notification-preview")
        let expected = try RelayV2NotificationPreview.decodeStrict(
            from: Data(fixture.canonicalPreviewJSON.utf8)
        )
        let source = UNMutableNotificationContent()
        source.title = "Untrusted APNs title"
        source.body = "Untrusted APNs body"
        source.categoryIdentifier = "UNTRUSTED_ACTIONS"
        source.sound = .default
        source.badge = 99
        source.userInfo = RelayV2NotificationServiceProcessor.authenticatedUserInfo(
            descriptor: fixture.descriptor
        ).merging(["untrusted": "must-not-survive"]) { current, _ in current }
        let processor = RelayV2NotificationServiceProcessor(
            loadPreviewKeys: {
                [RelayV2PreviewKeyRecord(
                    accountID: "acc_fixture",
                    privateKey: try Data(hex: fixture.recipientPrivateKeyHex),
                    agentAgreementPublicKey: try Data(hex: fixture.senderPublicKeyHex),
                    generation: 1
                )]
            },
            nowMilliseconds: { 1_784_449_950_000 }
        )

        let rendered = processor.render(source)
        XCTAssertEqual(rendered.title, expected.title)
        XCTAssertEqual(rendered.body, expected.body)
        XCTAssertEqual(rendered.threadIdentifier, expected.threadToken)
        XCTAssertEqual(rendered.categoryIdentifier, "HERMES_APPROVAL")
        XCTAssertNotNil(rendered.sound)
        XCTAssertNil(rendered.userInfo["untrusted"])
        XCTAssertEqual(
            Set(rendered.userInfo.keys.compactMap { $0 as? String }),
            ["h_v", "class", "nid", "enc", "ct", "exp", "collapse", "sound"]
        )

        let fallback = RelayV2NotificationServiceProcessor(
            loadPreviewKeys: { [] },
            nowMilliseconds: { 1_784_449_950_000 }
        ).render(source)
        XCTAssertEqual(fallback.title, "Hermes")
        XCTAssertEqual(fallback.body, "Open Hermes to view this update.")
        XCTAssertEqual(fallback.categoryIdentifier, "")
        XCTAssertEqual(fallback.threadIdentifier, "")
        XCTAssertNil(fallback.sound)
        XCTAssertNil(fallback.badge)
        XCTAssertTrue(fallback.userInfo.isEmpty)

        let validAction: [String: JSONValue] = [
            "request_id": "req_test",
            "session_id": "sess_test",
            "capability": "cap_test",
            "allowed_decisions": ["approve_once", "deny"],
            "destructive": false,
            "device_id": "dev_test",
            "device_generation": 1,
        ]
        XCTAssertEqual(
            RelayV2NotificationServiceProcessor.approvedCategory(
                "HERMES_APPROVAL",
                notificationClass: .approval,
                action: validAction
            ),
            "HERMES_APPROVAL"
        )
        var expandedAction = validAction
        expandedAction["command"] = "forbidden"
        XCTAssertEqual(
            RelayV2NotificationServiceProcessor.approvedCategory(
                "HERMES_APPROVAL",
                notificationClass: .approval,
                action: expandedAction
            ),
            ""
        )
        XCTAssertEqual(
            RelayV2NotificationServiceProcessor.approvedCategory(
                "HERMES_CLARIFY",
                notificationClass: .update,
                action: validAction
            ),
            ""
        )
    }

    func testNotificationPreviewPinsNullableKeysAndExactApprovalActions() throws {
        let update = try RelayV2NotificationPreview(
            notificationID: "nid_update", notificationClass: .update,
            title: "Hermes", body: "A turn finished", threadToken: "thread_update",
            category: nil, expiresAtMilliseconds: 9_999_999_999_999, action: nil
        )
        let encoded = try update.canonicalJSON()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertTrue(object["category"] is NSNull)
        XCTAssertTrue(object["action"] is NSNull)
        XCTAssertEqual(try RelayV2NotificationPreview.decodeStrict(from: encoded), update)

        let validAction: [String: JSONValue] = [
            "request_id": .string("req_test"),
            "session_id": .string("sess_test"),
            "capability": .string("cap_test"),
            "allowed_decisions": .array([.string("approve_once"), .string("deny")]),
            "destructive": .bool(false),
            "device_id": .string("dev_test"),
            "device_generation": .number(1),
        ]
        XCTAssertNoThrow(try RelayV2NotificationPreview(
            notificationID: "nid_approval", notificationClass: .approval,
            title: "Approval", body: "Permission requested", threadToken: "thread_approval",
            category: "HERMES_APPROVAL", expiresAtMilliseconds: 9_999_999_999_999,
            action: validAction
        ))
        var unknown = validAction
        unknown["command"] = .string("forbidden")
        XCTAssertThrowsError(try RelayV2NotificationPreview(
            notificationID: "nid_approval", notificationClass: .approval,
            title: "Approval", body: "Permission requested", threadToken: "thread_approval",
            category: "HERMES_APPROVAL", expiresAtMilliseconds: 9_999_999_999_999,
            action: unknown
        ))
        var invalidDecision = validAction
        invalidDecision["allowed_decisions"] = .array([.string("always_allow")])
        XCTAssertThrowsError(try RelayV2NotificationPreview(
            notificationID: "nid_approval", notificationClass: .approval,
            title: "Approval", body: "Permission requested", threadToken: "thread_approval",
            category: "HERMES_APPROVAL", expiresAtMilliseconds: 9_999_999_999_999,
            action: invalidDecision
        ))
        var duplicateDecision = validAction
        duplicateDecision["allowed_decisions"] = .array([.string("deny"), .string("deny")])
        XCTAssertThrowsError(try RelayV2NotificationPreview(
            notificationID: "nid_approval", notificationClass: .approval,
            title: "Approval", body: "Permission requested", threadToken: "thread_approval",
            category: "HERMES_APPROVAL", expiresAtMilliseconds: 9_999_999_999_999,
            action: duplicateDecision
        ))
    }

    func testStrictModelsRejectUnknownFieldsAndInvalidCollapse() throws {
        let fixture: AuthFixture = try loadFixture("auth-envelope")
        var object = try JSONSerialization.jsonObject(
            with: fixture.outerEnvelope.canonicalJSON()
        ) as! [String: Any]
        object["plaintext"] = "forbidden"
        XCTAssertThrowsError(try RelayV2OuterEnvelope.decodeStrict(
            from: JSONSerialization.data(withJSONObject: object)
        ))

        XCTAssertThrowsError(try RelayV2OuterHeader(
            source: "rte_agent", destination: "rte_device",
            messageID: RelayV2Wire.randomMessageID(), messageClass: .state,
            expiresAtMilliseconds: 10, recipientKeyGeneration: 1,
            collapse: String(repeating: "a", count: 65)
        ))
        XCTAssertThrowsError(try RelayV2NotificationPreview(
            notificationID: "nid_test", notificationClass: .approval,
            title: "", body: "body", threadToken: "thread",
            category: "HERMES_APPROVAL", expiresAtMilliseconds: 10, action: nil
        ))
    }

    func testSecureInnerMessageRejectsFloatingPointBodyValues() throws {
        XCTAssertThrowsError(try RelayV2SecureMessage(
            messageID: RelayV2Wire.base64URL(Data(repeating: 1, count: 16)),
            kind: .rpcRequest,
            senderKeyGeneration: 1,
            createdAtMilliseconds: 1,
            expiresAtMilliseconds: 2,
            body: ["fraction": .number(1.5)]
        ))
        let raw = Data("{\"body\":{\"fraction\":1.0},\"created_at_ms\":1,\"expires_at_ms\":2,\"kind\":\"rpc_request\",\"mid\":\"AQEBAQEBAQEBAQEBAQEBAQ\",\"sender_key_generation\":1,\"v\":2}".utf8)
        XCTAssertThrowsError(try RelayV2SecureMessage.decodeStrict(from: raw))
    }

    func testPairAcceptRejectsRelayKeyGenerationAboveUInt32WithoutTrapping() throws {
        let message = try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(),
            kind: .pairAccept,
            senderKeyGeneration: 1,
            createdAtMilliseconds: 1,
            expiresAtMilliseconds: 2,
            body: [
                "device_id": "dev_overflow",
                "relay_instance_id": "rly_overflow",
                "device_route": "rte_overflow",
                "stream_id": "str_overflow",
                "relay_key_generation": .number(Double(UInt32.max) + 1),
                "push_binding_id": .null,
                "capabilities": .array([]),
            ]
        )
        XCTAssertThrowsError(try RelayV2PairAccept(message: message)) { error in
            XCTAssertEqual(
                error as? RelayV2ProtocolError,
                .invalidArgument(field: "pair_accept")
            )
        }
    }

    private func loadFixture<T: Decodable>(_ name: String) throws -> T {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

final class RelayV2PersistenceTests: XCTestCase {
    func testFreshDatabaseRunsCompleteMigrationChain() async throws {
        let database = try RelayV2Database.inMemory()
        try await database.registerAccount(
            accountID: "acc_fresh",
            localDeviceID: "dev_fresh",
            agentRouteID: "rte_agent",
            deviceRouteID: "rte_device",
            currentKeyGeneration: 1,
            nowMilliseconds: 1
        )
        let initialStream = try await database.streamState(
            accountID: "acc_fresh", streamID: "stream"
        )
        XCTAssertNil(initialStream)
    }

    func testEveryProtocolEventPersistsAndTurnStartedDoesNotPoisonContinuity() async throws {
        let database = try RelayV2Database.inMemory()
        let kinds = [
            "turn.started", "turn.completed", "approval.request", "clarify.request",
            "status", "title", "snapshot",
        ]
        let frames = kinds.map {
            RelayV2WireFrame(sessionID: "s", turnID: "turn", kind: $0, body: [:])
        }
        try await database.apply(
            accountID: "acc", messageID: "events",
            batch: .init(streamID: "str", firstSequence: 1, frames: frames),
            receivedAtMilliseconds: 1
        )
        let state = try await database.streamState(accountID: "acc", streamID: "str")
        let through = try XCTUnwrap(state).throughSequence
        let stored = try await database.events(
            accountID: "acc", streamID: "str", firstSequence: 1,
            throughSequence: Int64(kinds.count)
        )
        XCTAssertEqual(through, Int64(kinds.count))
        XCTAssertEqual(stored.map(\.kind), kinds)

        try await database.apply(
            accountID: "acc", messageID: "after-events",
            batch: .init(
                streamID: "str", firstSequence: Int64(kinds.count + 1),
                frames: [fullFrame(session: "s", item: "answer", revision: 1, text: "ok")]
            ),
            receivedAtMilliseconds: 2
        )
        let projected = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(projected.first?.body?["text"]?.stringValue, "ok")
    }

    func testStandaloneCheckpointHealsForcedGapAndAuthorizesLateMissingFrames() async throws {
        let database = try RelayV2Database.inMemory()
        try await database.apply(
            accountID: "acc", messageID: "one",
            batch: .init(
                streamID: "str", firstSequence: 1,
                frames: [fullFrame(session: "s", item: "old", revision: 1, text: "old")]
            ),
            receivedAtMilliseconds: 1
        )
        let healedItem = fullItemBody(session: "s", item: "healed", revision: 1, ord: 0, text: "healed")
        try await database.applyCheckpoint(
            accountID: "acc", messageID: "checkpoint",
            body: [
                "stream_id": "str", "through_seq": 10, "session_id": "s",
                "snapshot_revision": 2, "replace": true,
                "items": .array([healedItem]), "tombstones": .array([]),
            ],
            receivedAtMilliseconds: 2
        )
        // A pre-checkpoint batch was never hashed locally. The authoritative
        // checkpoint permits it to be ignored instead of reporting divergence.
        try await database.apply(
            accountID: "acc", messageID: "late-two",
            batch: .init(
                streamID: "str", firstSequence: 2,
                frames: [RelayV2WireFrame(sessionID: "s", turnID: "turn", kind: "status", body: [:])]
            ),
            receivedAtMilliseconds: 3
        )
        try await database.apply(
            accountID: "acc", messageID: "eleven",
            batch: .init(
                streamID: "str", firstSequence: 11,
                frames: [fullFrame(session: "s", item: "next", revision: 1, text: "next")]
            ),
            receivedAtMilliseconds: 4
        )
        let healedState = try await database.streamState(accountID: "acc", streamID: "str")
        let healedItems = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(healedState?.throughSequence, 11)
        XCTAssertEqual(Set(healedItems.map(\.itemID)), ["healed", "next"])
    }

    func testSequencedCheckpointCanResetContinuityAcrossGap() async throws {
        let database = try RelayV2Database.inMemory()
        try await database.apply(
            accountID: "acc", messageID: "one",
            batch: .init(streamID: "str", firstSequence: 1, frames: [
                RelayV2WireFrame(sessionID: "s", turnID: "turn", kind: "turn.started", body: [:])
            ]), receivedAtMilliseconds: 1
        )
        let checkpoint: JSONValue = [
            "stream_id": "str", "through_seq": 9, "session_id": "s",
            "snapshot_revision": 2, "replace": true,
            "items": .array([fullItemBody(session: "s", item: "answer", revision: 1, ord: 0, text: "restored")]),
            "tombstones": .array([]),
        ]
        try await database.apply(
            accountID: "acc", messageID: "healing-batch",
            batch: .init(streamID: "str", firstSequence: 10, frames: [
                RelayV2WireFrame(sessionID: "s", turnID: nil, kind: "checkpoint", body: checkpoint),
                RelayV2WireFrame(sessionID: "s", turnID: "turn", kind: "turn.completed", body: [:]),
            ]), receivedAtMilliseconds: 2
        )
        let checkpointState = try await database.streamState(accountID: "acc", streamID: "str")
        let checkpointItems = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(checkpointState?.throughSequence, 11)
        XCTAssertEqual(checkpointItems.first?.body?["text"]?.stringValue, "restored")
    }

    func testStaleCheckpointCannotReplaceNewerProjection() async throws {
        let database = try RelayV2Database.inMemory()
        let newer: [String: JSONValue] = [
            "stream_id": "str", "through_seq": 20, "session_id": "s",
            "snapshot_revision": 2, "replace": true,
            "items": .array([
                fullItemBody(session: "s", item: "answer", revision: 2, ord: 0, text: "B")
            ]),
            "tombstones": .array([]),
        ]
        try await database.applyCheckpoint(
            accountID: "acc", messageID: "newer", body: newer,
            receivedAtMilliseconds: 1
        )
        let stale: [String: JSONValue] = [
            "stream_id": "str", "through_seq": 10, "session_id": "s",
            "snapshot_revision": 1, "replace": true,
            "items": .array([
                fullItemBody(session: "s", item: "answer", revision: 1, ord: 0, text: "A")
            ]),
            "tombstones": .array([]),
        ]
        try await database.applyCheckpoint(
            accountID: "acc", messageID: "stale", body: stale,
            receivedAtMilliseconds: 2
        )
        let items = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(items.first?.body?["text"]?.stringValue, "B")
        let sawStale = try await database.hasSeen(accountID: "acc", messageID: "stale")
        let finalStream = try await database.streamState(accountID: "acc", streamID: "str")
        XCTAssertTrue(sawStale)
        XCTAssertEqual(finalStream?.throughSequence, 20)
    }

    func testEqualCheckpointRevisionRequiresIdenticalCanonicalContent() async throws {
        let database = try RelayV2Database.inMemory()
        let accepted: [String: JSONValue] = [
            "stream_id": "str", "through_seq": 20, "session_id": "s",
            "snapshot_revision": 2, "replace": true,
            "items": .array([
                fullItemBody(session: "s", item: "answer", revision: 2, ord: 0, text: "B")
            ]),
            "tombstones": .array([]),
        ]
        try await database.applyCheckpoint(
            accountID: "acc", messageID: "first", body: accepted,
            receivedAtMilliseconds: 1
        )
        try await database.applyCheckpoint(
            accountID: "acc", messageID: "exact-duplicate", body: accepted,
            receivedAtMilliseconds: 2
        )
        var divergent = accepted
        divergent["items"] = .array([
            fullItemBody(session: "s", item: "answer", revision: 2, ord: 0, text: "A")
        ])
        await XCTAssertThrowsErrorAsync {
            try await database.applyCheckpoint(
                accountID: "acc", messageID: "same-revision-different-content",
                body: divergent, receivedAtMilliseconds: 3
            )
        }
        let items = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(items.first?.body?["text"]?.stringValue, "B")
    }

    func testReplacementCheckpointTombstonesOnlyOmittedItemsAtOrBelowSnapshotRevision() async throws {
        let database = try RelayV2Database.inMemory()
        try await database.apply(
            accountID: "acc", messageID: "base-items",
            batch: .init(streamID: "str", firstSequence: 1, frames: [
                fullFrame(session: "s", item: "old-omitted", revision: 1, text: "old"),
                fullFrame(session: "s", item: "newer-omitted", revision: 5, text: "newer"),
            ]),
            receivedAtMilliseconds: 1
        )
        let checkpoint: JSONValue = [
            "stream_id": "str", "through_seq": 2, "session_id": "s",
            "snapshot_revision": 2, "replace": true,
            "items": .array([]), "tombstones": .array([]),
        ]
        try await database.apply(
            accountID: "acc", messageID: "replacement",
            batch: .init(streamID: "str", firstSequence: 3, frames: [
                RelayV2WireFrame(
                    sessionID: "s", turnID: nil, kind: "checkpoint", body: checkpoint
                ),
            ]),
            receivedAtMilliseconds: 2
        )

        var items = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(items.map(\.itemID), ["newer-omitted"])
        XCTAssertEqual(items.first?.revision, 5)

        // The replacement omission is an implicit deletion through snapshot rev 2.
        // A late rev-2 full frame must not resurrect it.
        try await database.apply(
            accountID: "acc", messageID: "stale-resurrection",
            batch: .init(
                streamID: "str", firstSequence: 4,
                frames: [
                    fullFrame(
                        session: "s", item: "old-omitted", revision: 2,
                        text: "must-not-resurrect"
                    ),
                ]
            ),
            receivedAtMilliseconds: 3
        )
        items = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(items.map(\.itemID), ["newer-omitted"])
    }

    func testEqualItemRevisionDivergenceRollsBackSeenWatermarkAndAck() async throws {
        let database = try RelayV2Database.inMemory()
        let original = fullFrame(session: "s", item: "answer", revision: 1, text: "A")
        try await database.apply(
            accountID: "acc", messageID: "original",
            batch: .init(streamID: "str", firstSequence: 1, frames: [original]),
            receivedAtMilliseconds: 1
        )
        let ack = try controlFixture(messageByte: 0xA5)
        await XCTAssertThrowsErrorAsync {
            try await database.apply(
                accountID: "acc", messageID: "divergent-equal-revision",
                batch: .init(
                    streamID: "str", firstSequence: 2,
                    frames: [
                        self.fullFrame(
                            session: "s", item: "answer", revision: 1, text: "B"
                        ),
                    ]
                ),
                receivedAtMilliseconds: 2,
                outboundControlEnvelope: ack,
                outboundStableKey: "str:2"
            )
        }
        let sawDivergent = try await database.hasSeen(
            accountID: "acc", messageID: "divergent-equal-revision"
        )
        let stateAfterDivergence = try await database.streamState(
            accountID: "acc", streamID: "str"
        )
        let pendingAfterDivergence = try await database.pendingControl(accountID: "acc")
        let itemsAfterDivergence = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertFalse(sawDivergent)
        XCTAssertEqual(stateAfterDivergence?.throughSequence, 1)
        XCTAssertTrue(pendingAfterDivergence.isEmpty)
        XCTAssertEqual(itemsAfterDivergence.first?.body?["text"]?.stringValue, "A")

        // A byte-semantically identical full item at the same revision is a valid
        // duplicate and may advance the independent stream sequence.
        try await database.apply(
            accountID: "acc", messageID: "exact-equal-revision",
            batch: .init(streamID: "str", firstSequence: 2, frames: [original]),
            receivedAtMilliseconds: 3
        )
        let stateAfterDuplicate = try await database.streamState(
            accountID: "acc", streamID: "str"
        )
        XCTAssertEqual(stateAfterDuplicate?.throughSequence, 2)
    }

    func testSameSemanticCheckpointAckReusesPendingCiphertext() async throws {
        let database = try RelayV2Database.inMemory()
        let body: [String: JSONValue] = [
            "stream_id": "str", "through_seq": 10, "session_id": "s",
            "snapshot_revision": 1, "replace": true,
            "items": .array([]), "tombstones": .array([]),
        ]
        let firstAck = try controlFixture(messageByte: 1)
        let replacementAck = try controlFixture(messageByte: 2)
        try await database.applyCheckpoint(
            accountID: "acc", messageID: "checkpoint-one", body: body,
            receivedAtMilliseconds: 1,
            outboundControlEnvelope: firstAck,
            outboundStableKey: "str:10"
        )
        try await database.applyCheckpoint(
            accountID: "acc", messageID: "checkpoint-two", body: body,
            receivedAtMilliseconds: 2,
            outboundControlEnvelope: replacementAck,
            outboundStableKey: "str:10"
        )
        let pending = try await database.pendingControl(accountID: "acc")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(
            pending.first?.envelopeJSON,
            try firstAck.canonicalJSON()
        )
        let sawSecondCheckpoint = try await database.hasSeen(
            accountID: "acc", messageID: "checkpoint-two"
        )
        XCTAssertTrue(sawSecondCheckpoint)

        let service = "ai.hermes.tests.ack-drain.\(UUID().uuidString)"
        let keyStore = RelayV2KeychainStore(service: service, previewAccessGroup: nil)
        var identity = RelayV2Identity.makeUnpaired(accountID: "acc")
        let agent = RelayV2Crypto.generateAgreementKeyPair()
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = agent.publicKey
        identity.agentSigningPublicKey = RelayV2Crypto.generateSigningKeyPair().publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayV2HubAcceptStub.self]
        RelayV2HubAcceptStub.reset()
        let client = try RelayV2Client(
            identity: identity, keyStore: keyStore, database: database,
            hub: RelayV2HubTransport(
                configuration: try .init(
                    baseURL: URL(string: "https://relay.example.test")!,
                    routeID: "rte_device",
                    routeSigningPrivateKey: try XCTUnwrap(identity.currentKeys).signingPrivateKey
                ),
                session: URLSession(configuration: configuration)
            ),
            workRepository: try WorkRepository(configuration: .init(
                containerURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("relay-v2-ack-work-\(UUID().uuidString)")
            ))
        )
        try await client.drainControlOutbox()
        let drainedControls = try await database.pendingControl(accountID: "acc")
        XCTAssertTrue(drainedControls.isEmpty)
        keyStore.deleteIdentity(accountID: identity.accountID)
    }

    func testOriginLiveAliasSurvivesDatabaseReopenAndKeepsAccountsIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-v2-alias-\(UUID().uuidString)")
        let configuration = RelayV2DatabaseConfiguration(containerURL: directory)
        var database: RelayV2Database? = try RelayV2Database(configuration: configuration)
        try await database?.bindSessionAlias(
            accountID: "acc_a", originSessionID: "origin", liveSessionID: "live",
            nowMilliseconds: 1
        )
        let initialOrigin = try await database?.originSessionID(
            accountID: "acc_a", liveSessionID: "live"
        )
        XCTAssertEqual(initialOrigin, "origin")
        database = nil
        let reopened = try RelayV2Database(configuration: configuration)
        let reopenedOrigin = try await reopened.originSessionID(
            accountID: "acc_a", liveSessionID: "live"
        )
        let reopenedLive = try await reopened.liveSessionID(
            accountID: "acc_a", originSessionID: "origin"
        )
        let otherAccountOrigin = try await reopened.originSessionID(
            accountID: "acc_b", liveSessionID: "live"
        )
        XCTAssertEqual(reopenedOrigin, "origin")
        XCTAssertEqual(reopenedLive, "live")
        XCTAssertNil(otherAccountOrigin)
    }

    func testDeltaUpdateDoesNotReorderItemsAndMetadataSurvives() async throws {
        let database = try RelayV2Database.inMemory()
        let first = RelayV2WireFrame(
            sessionID: "s", turnID: "turn-a", kind: "item.started",
            body: fullItemBody(session: "s", item: "first", revision: 1, ord: 0, text: "a")
        )
        let second = RelayV2WireFrame(
            sessionID: "s", turnID: "turn-a", kind: "item.completed",
            body: fullItemBody(session: "s", item: "second", revision: 1, ord: 1, text: "b")
        )
        try await database.apply(
            accountID: "acc", messageID: "items",
            batch: .init(streamID: "str", firstSequence: 1, frames: [first, second]),
            receivedAtMilliseconds: 1
        )
        try await database.apply(
            accountID: "acc", messageID: "delta",
            batch: .init(
                streamID: "str", firstSequence: 3,
                frames: [deltaFrame(session: "s", item: "first", from: 1, offset: 1, text: "!")]
            ),
            receivedAtMilliseconds: 99
        )
        let items = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(items.map(\.itemID), ["first", "second"])
        XCTAssertEqual(items.map(\.turnID), ["turn-a", "turn-a"])
        XCTAssertEqual(items.map(\.ordinal), [0, 1])
        XCTAssertEqual(items.first?.body?["text"]?.stringValue, "a!")
    }

    func testSemanticDeliveryReceiptReusesFirstPendingCiphertext() async throws {
        let database = try RelayV2Database.inMemory()
        let header = try RelayV2OuterHeader(
            source: "rte_device", destination: "rte_agent",
            messageID: RelayV2Wire.base64URL(Data(repeating: 9, count: 16)),
            messageClass: .control, expiresAtMilliseconds: 9_999_999,
            recipientKeyGeneration: 1
        )
        let first = try RelayV2OuterEnvelope(
            header: header, encapsulatedKey: Data(repeating: 1, count: 32),
            ciphertext: Data(repeating: 2, count: 16), signature: Data(repeating: 3, count: 64)
        )
        try await database.recordSeenAndQueueControl(
            accountID: "acc", messageID: "incoming", envelope: first,
            kind: "delivery_receipt", stableKey: "incoming", receivedAtMilliseconds: 1
        )
        let pending = try await database.pendingControl(accountID: "acc")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].envelopeJSON, try first.canonicalJSON())

        let changed = try RelayV2OuterEnvelope(
            header: header, encapsulatedKey: Data(repeating: 4, count: 32),
            ciphertext: Data(repeating: 5, count: 16), signature: Data(repeating: 6, count: 64)
        )
        try await database.recordSeenAndQueueControl(
            accountID: "acc", messageID: "incoming", envelope: changed,
            kind: "delivery_receipt", stableKey: "incoming", receivedAtMilliseconds: 2
        )
        let stillPending = try await database.pendingControl(accountID: "acc")
        XCTAssertEqual(stillPending.first?.envelopeJSON, try first.canonicalJSON())
    }

    func testRevisionOffsetsSessionPartitionAndConflictingSequenceRollback() async throws {
        let database = try RelayV2Database.inMemory()
        let initial = RelayV2FrameBatch(
            streamID: "str_test",
            firstSequence: 1,
            frames: [
                fullFrame(session: "s1", item: "same", revision: 1, text: "hé"),
                fullFrame(session: "s2", item: "same", revision: 1, text: "other"),
                deltaFrame(session: "s1", item: "same", from: 1, offset: 3, text: "!"),
            ]
        )
        try await database.apply(accountID: "acc_test", messageID: "m1", batch: initial, receivedAtMilliseconds: 1)
        let sessionOneItems = try await database.items(accountID: "acc_test", sessionID: "s1")
        let sessionTwoItems = try await database.items(accountID: "acc_test", sessionID: "s2")
        XCTAssertEqual(sessionOneItems.first?.body?["text"]?.stringValue, "hé!")
        XCTAssertEqual(sessionTwoItems.first?.body?["text"]?.stringValue, "other")

        // Byte-identical sequence replay under a new envelope is harmless.
        try await database.apply(accountID: "acc_test", messageID: "m2", batch: initial, receivedAtMilliseconds: 2)
        let conflicting = RelayV2FrameBatch(
            streamID: "str_test", firstSequence: 3,
            frames: [deltaFrame(session: "s1", item: "same", from: 1, offset: 2, text: "different")]
        )
        await XCTAssertThrowsErrorAsync {
            try await database.apply(
                accountID: "acc_test", messageID: "m_conflict",
                batch: conflicting, receivedAtMilliseconds: 3
            )
        }
        let recordedConflict = try await database.hasSeen(accountID: "acc_test", messageID: "m_conflict")
        XCTAssertFalse(recordedConflict)
    }

    func testBadOffsetRollsBackSeenWatermarkAndBodyAtomically() async throws {
        let database = try RelayV2Database.inMemory()
        try await database.apply(
            accountID: "acc", messageID: "base",
            batch: RelayV2FrameBatch(
                streamID: "str", firstSequence: 1,
                frames: [fullFrame(session: "s", item: "i", revision: 1, text: "hello")]
            ),
            receivedAtMilliseconds: 1
        )
        let invalid = RelayV2FrameBatch(
            streamID: "str", firstSequence: 2,
            frames: [deltaFrame(session: "s", item: "i", from: 1, offset: 99, text: "!")]
        )
        await XCTAssertThrowsErrorAsync {
            try await database.apply(
                accountID: "acc", messageID: "bad", batch: invalid, receivedAtMilliseconds: 2
            )
        }
        let state = try await database.streamState(accountID: "acc", streamID: "str")
        let items = try await database.items(accountID: "acc", sessionID: "s")
        let recordedInvalidBatch = try await database.hasSeen(accountID: "acc", messageID: "bad")
        XCTAssertEqual(state?.throughSequence, 1)
        XCTAssertEqual(items.first?.body?["text"]?.stringValue, "hello")
        XCTAssertFalse(recordedInvalidBatch)
    }

    func testHighDeltaBatchCoalescesIntoOneAppendChunkAndMaterializesExactly() async throws {
        let database = try RelayV2Database.inMemory()
        try await database.apply(
            accountID: "acc", messageID: "base",
            batch: .init(
                streamID: "str", firstSequence: 1,
                frames: [fullFrame(session: "s", item: "i", revision: 1, text: "a")]
            ),
            receivedAtMilliseconds: 1
        )

        let deltaCount = 2_048
        let frames = (0..<deltaCount).map { index in
            deltaFrame(
                session: "s",
                item: "i",
                from: index + 1,
                offset: 1 + index * 4,
                text: "🙂"
            )
        }
        let result = try await database.apply(
            accountID: "acc", messageID: "many-deltas",
            batch: .init(streamID: "str", firstSequence: 2, frames: frames),
            receivedAtMilliseconds: 2
        )

        XCTAssertEqual(result.committedTextDeltas.count, 1)
        XCTAssertEqual(result.committedTextDeltas.first?.fromRevision, 1)
        XCTAssertEqual(result.committedTextDeltas.first?.toRevision, Int64(deltaCount + 1))
        XCTAssertEqual(result.committedTextDeltas.first?.data, String(repeating: "🙂", count: deltaCount))
        let storage = try await database.textChunkStorageForTesting(
            accountID: "acc", sessionID: "s", itemID: "i"
        )
        XCTAssertEqual(storage.count, 1)
        XCTAssertEqual(storage.baseText, "a", "base JSON must not grow once per delta")
        XCTAssertEqual(storage.appendedUTF8Count, Int64(deltaCount * 4))
        let storedItems = try await database.items(accountID: "acc", sessionID: "s")
        let item = try XCTUnwrap(storedItems.first)
        XCTAssertEqual(item.revision, Int64(deltaCount + 1))
        XCTAssertEqual(
            item.body?["text"]?.stringValue,
            "a" + String(repeating: "🙂", count: deltaCount)
        )

        try await database.apply(
            accountID: "acc", messageID: "terminal-replacement",
            batch: .init(
                streamID: "str",
                firstSequence: Int64(deltaCount + 2),
                frames: [fullFrame(
                    session: "s", item: "i", revision: deltaCount + 2,
                    text: "authoritative"
                )]
            ),
            receivedAtMilliseconds: 3
        )
        let replacedStorage = try await database.textChunkStorageForTesting(
            accountID: "acc", sessionID: "s", itemID: "i"
        )
        XCTAssertEqual(replacedStorage.count, 0)
        XCTAssertEqual(replacedStorage.baseText, "authoritative")
        let replacedItems = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(replacedItems.first?.body?["text"]?.stringValue, "authoritative")
    }

    func testHighDeltaBatchWithInvalidTailRollsBackChunkWatermarkSeenAndAck() async throws {
        let database = try RelayV2Database.inMemory()
        try await database.apply(
            accountID: "acc", messageID: "base",
            batch: .init(
                streamID: "str", firstSequence: 1,
                frames: [fullFrame(session: "s", item: "i", revision: 1, text: "x")]
            ),
            receivedAtMilliseconds: 1
        )
        var frames = (0..<512).map { index in
            deltaFrame(
                session: "s", item: "i", from: index + 1,
                offset: index + 1, text: "y"
            )
        }
        frames.append(deltaFrame(
            session: "s", item: "i", from: 513,
            offset: 99_999, text: "bad"
        ))
        let ack = try controlFixture(messageByte: 0xD1)
        await XCTAssertThrowsErrorAsync {
            try await database.apply(
                accountID: "acc", messageID: "invalid-tail",
                batch: .init(streamID: "str", firstSequence: 2, frames: frames),
                receivedAtMilliseconds: 2,
                outboundControlEnvelope: ack,
                outboundStableKey: "str:514"
            )
        }

        let storage = try await database.textChunkStorageForTesting(
            accountID: "acc", sessionID: "s", itemID: "i"
        )
        XCTAssertEqual(storage.count, 0)
        XCTAssertEqual(storage.baseText, "x")
        let stream = try await database.streamState(accountID: "acc", streamID: "str")
        let sawInvalid = try await database.hasSeen(
            accountID: "acc", messageID: "invalid-tail"
        )
        let pendingControl = try await database.pendingControl(accountID: "acc")
        XCTAssertEqual(stream?.throughSequence, 1)
        XCTAssertFalse(sawInvalid)
        XCTAssertTrue(pendingControl.isEmpty)
    }

    func testThousandsOfSeparateDeltaCommitsKeepDurableByteEndAndRollbackAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-v2-separate-deltas-\(UUID().uuidString)")
        let configuration = RelayV2DatabaseConfiguration(containerURL: directory)
        var database = try RelayV2Database(configuration: configuration)
        try await database.apply(
            accountID: "acc", messageID: "base",
            batch: .init(
                streamID: "str", firstSequence: 1,
                frames: [fullFrame(session: "s", item: "i", revision: 1, text: "a")]
            ),
            receivedAtMilliseconds: 1
        )

        let deltaCount = 2_048
        let pieces = (0..<deltaCount).map { index in
            switch index % 3 {
            case 0: return "🙂"
            case 1: return "é"
            default: return "x"
            }
        }
        var byteEnd = 1
        for (index, piece) in pieces.enumerated() {
            try await database.apply(
                accountID: "acc", messageID: "delta-\(index)",
                batch: .init(
                    streamID: "str", firstSequence: Int64(index + 2),
                    frames: [deltaFrame(
                        session: "s", item: "i", from: index + 1,
                        offset: byteEnd, text: piece
                    )]
                ),
                receivedAtMilliseconds: Int64(index + 2)
            )
            byteEnd += piece.utf8.count

            // Reopening mid-stream proves the next offset comes from durable
            // item state, not an actor-only cache rebuilt by scanning chunks.
            if index == deltaCount / 2 {
                database = try RelayV2Database(configuration: configuration)
            }
        }

        var storage = try await database.textChunkStorageForTesting(
            accountID: "acc", sessionID: "s", itemID: "i"
        )
        XCTAssertEqual(storage.count, deltaCount, "every separate commit owns one chunk")
        XCTAssertEqual(storage.textUTF8End, Int64(byteEnd))
        XCTAssertEqual(storage.appendedUTF8Count, Int64(byteEnd - 1))
        var storedItems = try await database.items(accountID: "acc", sessionID: "s")
        var item = try XCTUnwrap(storedItems.first)
        XCTAssertEqual(item.revision, Int64(deltaCount + 1))
        XCTAssertEqual(item.body?["text"]?.stringValue, "a" + pieces.joined())

        // Force a real item/chunk/end update before the invalid tail. The
        // intervening non-delta frame flushes the first append inside the same
        // transaction; the bad tail must roll all of it back.
        let invalidMessageID = "invalid-after-separate-commits"
        await XCTAssertThrowsErrorAsync {
            try await database.apply(
                accountID: "acc", messageID: invalidMessageID,
                batch: .init(
                    streamID: "str", firstSequence: Int64(deltaCount + 2),
                    frames: [
                        self.deltaFrame(
                            session: "s", item: "i", from: deltaCount + 1,
                            offset: byteEnd, text: "!"
                        ),
                        RelayV2WireFrame(
                            sessionID: "s", turnID: "turn", kind: "status", body: [:]
                        ),
                        self.deltaFrame(
                            session: "s", item: "i", from: deltaCount + 2,
                            offset: 999_999, text: "bad"
                        ),
                    ]
                ),
                receivedAtMilliseconds: 9_000
            )
        }
        storage = try await database.textChunkStorageForTesting(
            accountID: "acc", sessionID: "s", itemID: "i"
        )
        storedItems = try await database.items(accountID: "acc", sessionID: "s")
        item = try XCTUnwrap(storedItems.first)
        let sawInvalidMessage = try await database.hasSeen(
            accountID: "acc", messageID: invalidMessageID
        )
        let streamAfterRollback = try await database.streamState(
            accountID: "acc", streamID: "str"
        )
        XCTAssertEqual(storage.count, deltaCount)
        XCTAssertEqual(storage.textUTF8End, Int64(byteEnd))
        XCTAssertEqual(item.revision, Int64(deltaCount + 1))
        XCTAssertFalse(sawInvalidMessage)
        XCTAssertEqual(streamAfterRollback?.throughSequence, Int64(deltaCount + 1))

        try await database.apply(
            accountID: "acc", messageID: "valid-retry",
            batch: .init(
                streamID: "str", firstSequence: Int64(deltaCount + 2),
                frames: [deltaFrame(
                    session: "s", item: "i", from: deltaCount + 1,
                    offset: byteEnd, text: "!"
                )]
            ),
            receivedAtMilliseconds: 9_001
        )

        try await database.apply(
            accountID: "acc", messageID: "terminal-replacement",
            batch: .init(
                streamID: "str", firstSequence: Int64(deltaCount + 3),
                frames: [fullFrame(
                    session: "s", item: "i", revision: deltaCount + 3,
                    text: "authoritative"
                )]
            ),
            receivedAtMilliseconds: 9_002
        )
        storage = try await database.textChunkStorageForTesting(
            accountID: "acc", sessionID: "s", itemID: "i"
        )
        XCTAssertEqual(storage.count, 0)
        XCTAssertEqual(storage.baseText, "authoritative")
        XCTAssertEqual(storage.textUTF8End, Int64("authoritative".utf8.count))

        database = try RelayV2Database(configuration: configuration)
        try await database.apply(
            accountID: "acc", messageID: "post-terminal-delta",
            batch: .init(
                streamID: "str", firstSequence: Int64(deltaCount + 4),
                frames: [deltaFrame(
                    session: "s", item: "i", from: deltaCount + 3,
                    offset: "authoritative".utf8.count, text: "🙂"
                )]
            ),
            receivedAtMilliseconds: 9_003
        )
        let finalItems = try await database.items(accountID: "acc", sessionID: "s")
        let finalItem = try XCTUnwrap(finalItems.first)
        XCTAssertEqual(finalItem.body?["text"]?.stringValue, "authoritative🙂")
    }

    func testV6ChunkMigrationBackfillsDurableUTF8EndForRestartedAppend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-v2-byte-end-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let configuration = RelayV2DatabaseConfiguration(containerURL: directory)
        do {
            let queue = try DatabaseQueue(path: configuration.databaseURL.path)
            try RelayV2Database.migrateForTesting(
                queue, through: "relay-v2-6-item-text-chunks"
            )
            let body = try JSONEncoder().encode(JSONValue.object(["text": .string("å")]))
            try await queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO relay_v2_items(
                            account_id,session_id,item_id,turn_id,ordinal,summary,sort_sequence,
                            revision,item_type,body_json,status,local_optimistic,updated_at_ms
                        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """,
                    arguments: [
                        "acc", "s", "i", "turn", 0, "", 1,
                        3, "agentMessage", body, "in_progress", false, 1,
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO relay_v2_item_text_chunks(
                            account_id,session_id,item_id,from_revision,through_revision,
                            utf8_count,text,created_at_ms
                        ) VALUES
                            ('acc','s','i',1,2,4,'🙂',1),
                            ('acc','s','i',2,3,1,'z',2)
                        """
                )
            }
        }

        let database = try RelayV2Database(configuration: configuration)
        var storage = try await database.textChunkStorageForTesting(
            accountID: "acc", sessionID: "s", itemID: "i"
        )
        XCTAssertEqual(storage.textUTF8End, 7, "2-byte base + 5 migrated chunk bytes")
        var migratedItems = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(migratedItems.first?.body?["text"]?.stringValue, "å🙂z")

        try await database.apply(
            accountID: "acc", messageID: "after-migration",
            batch: .init(
                streamID: "str", firstSequence: 1,
                frames: [deltaFrame(
                    session: "s", item: "i", from: 3, offset: 7, text: "!"
                )]
            ),
            receivedAtMilliseconds: 3
        )
        storage = try await database.textChunkStorageForTesting(
            accountID: "acc", sessionID: "s", itemID: "i"
        )
        XCTAssertEqual(storage.textUTF8End, 8)
        migratedItems = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(migratedItems.first?.body?["text"]?.stringValue, "å🙂z!")
    }

    func testTombstonePrecedenceAndCheckpointPreservesOptimisticWork() async throws {
        let database = try RelayV2Database.inMemory()
        try await database.insertOptimisticItem(
            accountID: "acc", sessionID: "s", itemID: "local",
            body: ["text": "queued"], nowMilliseconds: 0
        )
        try await database.apply(
            accountID: "acc", messageID: "base",
            batch: RelayV2FrameBatch(
                streamID: "str", firstSequence: 1,
                frames: [fullFrame(session: "s", item: "remote", revision: 1, text: "old")]
            ), receivedAtMilliseconds: 1
        )
        let checkpointBody: JSONValue = [
            "stream_id": "str", "through_seq": 1, "session_id": "s",
            "snapshot_revision": 2, "replace": true,
            "items": .array([]),
            "tombstones": .array([["item_id": "remote", "deleted_at_revision": 2]]),
        ]
        try await database.apply(
            accountID: "acc", messageID: "checkpoint",
            batch: RelayV2FrameBatch(
                streamID: "str", firstSequence: 2,
                frames: [RelayV2WireFrame(sessionID: "s", turnID: nil, kind: "checkpoint", body: checkpointBody)]
            ), receivedAtMilliseconds: 2
        )
        // An equal-revision full item cannot resurrect the tombstoned row.
        try await database.apply(
            accountID: "acc", messageID: "late",
            batch: RelayV2FrameBatch(
                streamID: "str", firstSequence: 3,
                frames: [fullFrame(session: "s", item: "remote", revision: 2, text: "resurrect")]
            ), receivedAtMilliseconds: 3
        )
        let items = try await database.items(accountID: "acc", sessionID: "s")
        XCTAssertEqual(items.map(\.itemID), ["local"])
        XCTAssertTrue(items[0].localOptimistic)
    }

    func testLateOptimisticInsertCannotOverwriteCanonicalRevision() async throws {
        let database = try RelayV2Database.inMemory()
        try await database.apply(
            accountID: "acc", messageID: "canonical",
            batch: .init(
                streamID: "str", firstSequence: 1,
                frames: [fullFrame(session: "s", item: "same", revision: 1, text: "agent")]
            ),
            receivedAtMilliseconds: 1
        )
        try await database.insertOptimisticItem(
            accountID: "acc", sessionID: "s", itemID: "same",
            body: ["text": "late-local"], nowMilliseconds: 2
        )
        let storedItems = try await database.items(accountID: "acc", sessionID: "s")
        let item = try XCTUnwrap(storedItems.first)
        XCTAssertEqual(item.revision, 1)
        XCTAssertFalse(item.localOptimistic)
        XCTAssertEqual(item.body?["text"]?.stringValue, "agent")
    }

    private func fullFrame(session: String, item: String, revision: Int, text: String) -> RelayV2WireFrame {
        RelayV2WireFrame(
            sessionID: session, turnID: "turn", kind: "item.completed",
            body: [
                "item_id": .string(item), "session_id": .string(session),
                "turn_id": .string("turn"), "type": .string("agentMessage"),
                "status": .string("completed"), "ord": .number(0),
                "rev": .number(Double(revision)), "summary": .string(""),
                "body": ["text": .string(text)],
            ]
        )
    }

    private func controlFixture(messageByte: UInt8) throws -> RelayV2OuterEnvelope {
        try RelayV2OuterEnvelope(
            header: RelayV2OuterHeader(
                source: "rte_device", destination: "rte_agent",
                messageID: RelayV2Wire.base64URL(Data(repeating: messageByte, count: 16)),
                messageClass: .control,
                expiresAtMilliseconds: 9_999_999_999_999,
                recipientKeyGeneration: 1
            ),
            encapsulatedKey: Data(repeating: messageByte, count: 32),
            ciphertext: Data(repeating: messageByte, count: 16),
            signature: Data(repeating: messageByte, count: 64)
        )
    }

    private func fullItemBody(
        session: String, item: String, revision: Int, ord: Int, text: String
    ) -> JSONValue {
        [
            "item_id": .string(item), "session_id": .string(session),
            "turn_id": .string("turn-a"), "type": .string("agentMessage"),
            "status": .string("completed"), "ord": .number(Double(ord)),
            "rev": .number(Double(revision)), "summary": .string("summary-\(item)"),
            "body": ["text": .string(text)],
        ]
    }

    private func deltaFrame(
        session: String, item: String, from: Int, offset: Int, text: String
    ) -> RelayV2WireFrame {
        RelayV2WireFrame(
            sessionID: session, turnID: "turn", kind: "item.delta",
            body: [
                "item_id": .string(item), "from_rev": .number(Double(from)),
                "to_rev": .number(Double(from + 1)),
                "ops": .array([[
                    "op": .string("append_utf8"), "path": .string("/body/text"),
                    "offset": .number(Double(offset)), "data": .string(text),
                ]]),
            ]
        )
    }
}

final class RelayV2InboundValidationTests: XCTestCase {
    private struct Fixture {
        let client: RelayV2Client
        let database: RelayV2Database
        let keyStore: RelayV2KeychainStore
        let identity: RelayV2Identity
        let agentAgreement: RelayV2RawKeyPair
        let agentSigning: RelayV2RawKeyPair
    }

    private func makeFixture() throws -> Fixture {
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.validation.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        var identity = RelayV2Identity.makeUnpaired(accountID: "acc_validation")
        let agreement = RelayV2Crypto.generateAgreementKeyPair()
        let signing = RelayV2Crypto.generateSigningKeyPair()
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = agreement.publicKey
        identity.agentSigningPublicKey = signing.publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        let database = try RelayV2Database.inMemory()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayV2HubAcceptStub.self]
        let client = try RelayV2Client(
            identity: identity,
            keyStore: keyStore,
            database: database,
            hub: RelayV2HubTransport(
                configuration: try .init(
                    baseURL: URL(string: "https://relay.example.test")!,
                    routeID: "rte_device",
                    routeSigningPrivateKey: try XCTUnwrap(identity.currentKeys).signingPrivateKey
                ),
                session: URLSession(configuration: configuration)
            ),
            workRepository: try WorkRepository(configuration: .init(
                containerURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("relay-v2-validation-work-\(UUID().uuidString)")
            ))
        )
        return Fixture(
            client: client, database: database, keyStore: keyStore, identity: identity,
            agentAgreement: agreement, agentSigning: signing
        )
    }

    private func fullItem(status: String = "completed") -> JSONValue {
        [
            "item_id": "item", "session_id": "session", "turn_id": "turn",
            "type": "agentMessage", "status": .string(status), "ord": 0, "rev": 1,
            "summary": "", "body": ["text": "hello"],
        ]
    }

    private func message(body: [String: JSONValue]) throws -> RelayV2SecureMessage {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        return try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(), kind: .frameBatch,
            senderKeyGeneration: 1, createdAtMilliseconds: now,
            expiresAtMilliseconds: now + 60_000, body: body
        )
    }

    func testFrameAndCheckpointSchemaBoundsAreEnforcedBeforePersistence() async throws {
        let fixture = try makeFixture()
        let validFrame: JSONValue = [
            "sid": "session", "turn": "turn", "kind": "item.completed",
            "body": fullItem(),
        ]
        try await fixture.client.validateInboundBody(try message(body: [
            "stream_id": "stream", "first_seq": 1, "frames": [validFrame],
        ]))

        let tooManyFrames = Array(repeating: validFrame, count: 1_025)
        await XCTAssertThrowsErrorAsync {
            try await fixture.client.validateInboundBody(try self.message(body: [
                "stream_id": "stream", "first_seq": 1, "frames": .array(tooManyFrames),
            ]))
        }
        let invalidItems: [[String: JSONValue]] = try [
            { var item = try XCTUnwrap(fullItem().objectValue); item["status"] = "unknown"; return item }(),
            { var item = try XCTUnwrap(fullItem().objectValue); item["ord"] = -1; return item }(),
            { var item = try XCTUnwrap(fullItem().objectValue); item["rev"] = 0; return item }(),
            { var item = try XCTUnwrap(fullItem().objectValue); item["item_id"] = "bad token"; return item }(),
            { var item = try XCTUnwrap(fullItem().objectValue); item["summary"] = .string(String(repeating: "s", count: 2_001)); return item }(),
            { var item = try XCTUnwrap(fullItem().objectValue); item["body"] = "not-an-object"; return item }(),
        ]
        for invalidItem in invalidItems {
            let invalidFrame: JSONValue = [
                "sid": "session", "turn": "turn", "kind": "item.completed",
                "body": .object(invalidItem),
            ]
            await XCTAssertThrowsErrorAsync {
                try await fixture.client.validateInboundBody(try self.message(body: [
                    "stream_id": "stream", "first_seq": 1, "frames": [invalidFrame],
                ]))
            }
        }

        let checkpoint = try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(), kind: .checkpoint,
            senderKeyGeneration: 1, createdAtMilliseconds: 1,
            expiresAtMilliseconds: 2,
            body: [
                "stream_id": "stream", "through_seq": 0, "session_id": "session",
                "snapshot_revision": 0, "replace": true,
                "items": .array(Array(repeating: fullItem(), count: 10_001)),
                "tombstones": .array([]),
            ]
        )
        await XCTAssertThrowsErrorAsync {
            try await fixture.client.validateInboundBody(checkpoint)
        }
        fixture.keyStore.deleteIdentity(accountID: fixture.identity.accountID)
    }

    func testAuthenticatedButSchemaInvalidFrameIsRejectedBeforeWAL() async throws {
        let fixture = try makeFixture()
        let invalidFrame: JSONValue = [
            "sid": "session", "turn": "turn", "kind": "item.completed",
            "body": fullItem(status: "not-a-status"),
        ]
        let inner = try message(body: [
            "stream_id": "stream", "first_seq": 1, "frames": [invalidFrame],
        ])
        let deviceKeys = try XCTUnwrap(fixture.identity.currentKeys)
        let header = try RelayV2OuterHeader(
            source: "rte_agent", destination: "rte_device", messageID: inner.messageID,
            messageClass: .realtime, expiresAtMilliseconds: inner.expiresAtMilliseconds,
            recipientKeyGeneration: 1
        )
        let envelope = try RelayV2Crypto.sealAuthenticatedEnvelope(
            header: header, message: inner,
            recipientPublicKey: try deviceKeys.agreementPublicKey,
            senderAgreementPrivateKey: fixture.agentAgreement.privateKey,
            senderSigningPrivateKey: fixture.agentSigning.privateKey,
            purpose: .chat, direction: .agentToDevice
        )
        await XCTAssertThrowsErrorAsync { try await fixture.client.ingest(envelope) }
        let wasSeen = try await fixture.database.hasSeen(
            accountID: fixture.identity.accountID, messageID: inner.messageID
        )
        let storedItems = try await fixture.database.items(
            accountID: fixture.identity.accountID, sessionID: "session"
        )
        XCTAssertFalse(wasSeen)
        XCTAssertTrue(storedItems.isEmpty)
        fixture.keyStore.deleteIdentity(accountID: fixture.identity.accountID)
    }

    func testWireIntegersCannotExceedSharedExactJSONRange() throws {
        let maximum = RelayV2.maximumJSONInteger
        XCTAssertNoThrow(try RelayV2OuterHeader(
            source: "source", destination: "destination",
            messageID: RelayV2Wire.randomMessageID(), messageClass: .control,
            expiresAtMilliseconds: maximum, recipientKeyGeneration: 1
        ))
        XCTAssertNoThrow(try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(), kind: .deliveryReceipt,
            senderKeyGeneration: 1, createdAtMilliseconds: maximum - 1,
            expiresAtMilliseconds: maximum,
            body: ["mid": .string(RelayV2Wire.randomMessageID())]
        ))
        let tooLarge = RelayV2.maximumJSONInteger + 1
        XCTAssertThrowsError(try RelayV2OuterHeader(
            source: "source", destination: "destination",
            messageID: RelayV2Wire.randomMessageID(), messageClass: .control,
            expiresAtMilliseconds: tooLarge, recipientKeyGeneration: 1
        ))
        XCTAssertThrowsError(try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(), kind: .deliveryReceipt,
            senderKeyGeneration: 1, createdAtMilliseconds: tooLarge,
            expiresAtMilliseconds: tooLarge, body: ["mid": .string(RelayV2Wire.randomMessageID())]
        ))

        let safeBodyMaximum = RelayV2.maximumExactlyRepresentableJSONInteger
        XCTAssertNoThrow(try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(), kind: .checkpoint,
            senderKeyGeneration: 1, createdAtMilliseconds: 1,
            expiresAtMilliseconds: 2, body: ["value": .number(safeBodyMaximum)]
        ))
        XCTAssertThrowsError(try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(), kind: .checkpoint,
            senderKeyGeneration: 1, createdAtMilliseconds: 1,
            expiresAtMilliseconds: 2, body: ["value": .number(safeBodyMaximum + 1)]
        ))

        XCTAssertEqual(JSONValue.number(safeBodyMaximum).intValue, Int(safeBodyMaximum))
        XCTAssertNil(JSONValue.number(Double(Int64.max - 1)).intValue)
        XCTAssertNil(JSONValue.number(Double(Int64.max)).intValue)
        XCTAssertNil(JSONValue.number(Double.greatestFiniteMagnitude).intValue)
        XCTAssertNotNil(JSONValue.number(Double(Int64.max)).coercedStringValue)
    }
}

private actor RelayV2HandshakeProbeCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

final class RelayV2TerminalRevocationTests: XCTestCase {
    private struct Fixture {
        let identity: RelayV2Identity
        let keyStore: RelayV2KeychainStore
        let databaseConfiguration: RelayV2DatabaseConfiguration
        let database: RelayV2Database
        let repository: WorkRepository
        let agentAgreement: RelayV2RawKeyPair
        let agentSigning: RelayV2RawKeyPair
    }

    private func makeFixture(accountID: String) throws -> Fixture {
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.terminal-revocation.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        var identity = RelayV2Identity.makeUnpaired(accountID: accountID)
        let agentAgreement = RelayV2Crypto.generateAgreementKeyPair()
        let agentSigning = RelayV2Crypto.generateSigningKeyPair()
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = agentAgreement.publicKey
        identity.agentSigningPublicKey = agentSigning.publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        let databaseConfiguration = RelayV2DatabaseConfiguration(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-v2-terminal-db-\(UUID().uuidString)")
        )
        let database = try RelayV2Database(configuration: databaseConfiguration)
        let repository = try WorkRepository(configuration: .init(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-v2-terminal-work-\(UUID().uuidString)")
        ))
        RelayV2HubAcceptStub.reset()
        return Fixture(
            identity: identity,
            keyStore: keyStore,
            databaseConfiguration: databaseConfiguration,
            database: database,
            repository: repository,
            agentAgreement: agentAgreement,
            agentSigning: agentSigning
        )
    }

    private func makeHub(
        identity: RelayV2Identity,
        readiness: @escaping @Sendable () async throws -> Void = {}
    ) throws -> RelayV2HubTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayV2HubAcceptStub.self]
        return RelayV2HubTransport(
            configuration: try .init(
                baseURL: URL(string: "https://relay.example.test")!,
                routeID: "rte_device",
                routeSigningPrivateKey: try XCTUnwrap(identity.currentKeys).signingPrivateKey
            ),
            session: URLSession(configuration: configuration),
            readinessProbeForTesting: readiness
        )
    }

    private func makeClient(
        fixture: Fixture,
        database: RelayV2Database? = nil,
        readiness: @escaping @Sendable () async throws -> Void = {}
    ) throws -> RelayV2Client {
        try RelayV2Client(
            identity: fixture.identity,
            keyStore: fixture.keyStore,
            database: database ?? fixture.database,
            hub: makeHub(identity: fixture.identity, readiness: readiness),
            workRepository: fixture.repository
        )
    }

    private func envelope(
        fixture: Fixture,
        kind: RelayV2SecureMessageKind,
        body: [String: JSONValue]
    ) throws -> (RelayV2SecureMessage, RelayV2OuterEnvelope) {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let message = try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(),
            kind: kind,
            senderKeyGeneration: 1,
            createdAtMilliseconds: now,
            expiresAtMilliseconds: now + 60_000,
            body: body
        )
        let outer = try RelayV2Crypto.sealAuthenticatedEnvelope(
            header: RelayV2OuterHeader(
                source: "rte_agent",
                destination: "rte_device",
                messageID: message.messageID,
                messageClass: .control,
                expiresAtMilliseconds: message.expiresAtMilliseconds,
                recipientKeyGeneration: 1
            ),
            message: message,
            recipientPublicKey: try XCTUnwrap(fixture.identity.currentKeys).agreementPublicKey,
            senderAgreementPrivateKey: fixture.agentAgreement.privateKey,
            senderSigningPrivateKey: fixture.agentSigning.privateKey,
            purpose: .control,
            direction: .agentToDevice
        )
        return (message, outer)
    }

    func testDeviceRevokeCrashBoundaryReconstructionRejectsReplayConnectAndSend() async throws {
        let fixture = try makeFixture(accountID: "acc_device_revoke_crash")
        let client = try makeClient(fixture: fixture)
        await client.setRevocationAfterTombstoneHookForTesting { source in
            source == "device_revoke"
        }
        let (message, inbound) = try envelope(
            fixture: fixture,
            kind: .deviceRevoke,
            body: ["device_id": .string(fixture.identity.deviceID)]
        )

        await XCTAssertThrowsErrorAsync { try await client.ingest(inbound) }
        let tombstone = try await fixture.database.accountRevocation(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(tombstone?.source, "device_revoke")
        XCTAssertEqual(tombstone?.messageID, message.messageID)
        let wasSeen = try await fixture.database.hasSeen(
            accountID: fixture.identity.accountID,
            messageID: message.messageID
        )
        XCTAssertFalse(wasSeen)
        let pendingControl = try await fixture.database.pendingControl(
            accountID: fixture.identity.accountID
        )
        XCTAssertTrue(pendingControl.isEmpty)
        XCTAssertEqual(RelayV2HubAcceptStub.acknowledgementCount, 0)
        XCTAssertNotNil(try fixture.keyStore.loadIdentity(accountID: fixture.identity.accountID))

        // Reconstruct both persistence and client as a process restart would.
        let reopenedDatabase = try RelayV2Database(
            configuration: fixture.databaseConfiguration
        )
        let restarted = try makeClient(fixture: fixture, database: reopenedDatabase)
        await XCTAssertThrowsErrorAsync { try await restarted.connect() }
        XCTAssertNil(try fixture.keyStore.loadIdentity(accountID: fixture.identity.accountID))
        await XCTAssertThrowsErrorAsync { try await restarted.ingest(inbound) }

        let command = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_after_revoke",
            clientMessageID: "msg_after_revoke",
            accountID: fixture.identity.accountID,
            sessionID: "session",
            kind: .interrupt,
            payload: ["session_id": "session"]
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await restarted.sendCommand(command, repository: fixture.repository)
        }
        XCTAssertTrue(RelayV2HubAcceptStub.postedBodies.isEmpty)
    }

    func testAuthenticatedRevokedRPCPersistsBeforeCommandResolutionOrReceipt() async throws {
        let fixture = try makeFixture(accountID: "acc_rpc_revoke_crash")
        let command = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_rpc_revoke",
            clientMessageID: "msg_rpc_revoke",
            accountID: fixture.identity.accountID,
            sessionID: "session",
            kind: .interrupt,
            payload: ["session_id": "session"]
        )
        let client = try makeClient(fixture: fixture)
        await client.setRevocationAfterTombstoneHookForTesting { source in
            source == "rpc_response"
        }
        let (message, inbound) = try envelope(
            fixture: fixture,
            kind: .rpcResponse,
            body: [
                "jsonrpc": "2.0",
                "id": .string(command.clientMessageID),
                "error": ["code": "REVOKED", "message": "device revoked"],
            ]
        )

        await XCTAssertThrowsErrorAsync { try await client.ingest(inbound) }
        let tombstone = try await fixture.database.accountRevocation(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(tombstone?.source, "rpc_response")
        let commands = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(commands.map(\.state), [.queued])
        let wasSeen = try await fixture.database.hasSeen(
            accountID: fixture.identity.accountID,
            messageID: message.messageID
        )
        XCTAssertFalse(wasSeen)
        let pendingControl = try await fixture.database.pendingControl(
            accountID: fixture.identity.accountID
        )
        XCTAssertTrue(pendingControl.isEmpty)
        XCTAssertEqual(RelayV2HubAcceptStub.acknowledgementCount, 0)
        XCTAssertNotNil(try fixture.keyStore.loadIdentity(accountID: fixture.identity.accountID))

        let restarted = try makeClient(
            fixture: fixture,
            database: try RelayV2Database(configuration: fixture.databaseConfiguration)
        )
        await XCTAssertThrowsErrorAsync { try await restarted.ingest(inbound) }
        XCTAssertNil(try fixture.keyStore.loadIdentity(accountID: fixture.identity.accountID))
        let replayedCommands = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(replayedCommands.map(\.state), [.queued])
    }

    func testRevokedHandshakeNeverOpensAndRestartDoesNotProbeAgain() async throws {
        let fixture = try makeFixture(accountID: "acc_handshake_revoke")
        let probes = RelayV2HandshakeProbeCounter()
        let client = try makeClient(fixture: fixture) {
            await probes.record()
            throw RelayV2ProtocolError.remote(.revoked, retryAfterSeconds: nil)
        }
        await client.setRevocationAfterTombstoneHookForTesting { source in
            source == "hub_handshake"
        }

        await XCTAssertThrowsErrorAsync { try await client.connect() }
        let initialProbeCount = await probes.count
        XCTAssertEqual(initialProbeCount, 1)
        let tombstone = try await fixture.database.accountRevocation(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(tombstone?.source, "hub_handshake")
        let failedState = await client.state
        XCTAssertNotEqual(failedState, .open)
        XCTAssertNotNil(try fixture.keyStore.loadIdentity(accountID: fixture.identity.accountID))
        let emptyOutbox = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertTrue(emptyOutbox.isEmpty)

        let restarted = try makeClient(
            fixture: fixture,
            database: try RelayV2Database(configuration: fixture.databaseConfiguration)
        ) {
            await probes.record()
        }
        await XCTAssertThrowsErrorAsync { try await restarted.connect() }
        let finalProbeCount = await probes.count
        XCTAssertEqual(finalProbeCount, 1)
        XCTAssertNil(try fixture.keyStore.loadIdentity(accountID: fixture.identity.accountID))
        let restartedState = await restarted.state
        XCTAssertNotEqual(restartedState, .open)
    }

    func testStaleReceiveCatchCannotPublishIntoFreshGeneration() async throws {
        let fixture = try makeFixture(accountID: "acc_stale_receive")
        let hub = try makeHub(identity: fixture.identity)
        let staleGeneration = await hub.connectionGenerationForTesting()
        await hub.disconnect()
        await hub.simulateReceiveFailureForTesting(
            generation: staleGeneration,
            error: .transport("stale socket")
        )
        let staleCount = await hub.publishedFailureCountForTestingValue()
        XCTAssertEqual(staleCount, 0)

        let currentGeneration = await hub.connectionGenerationForTesting()
        await hub.simulateReceiveFailureForTesting(
            generation: currentGeneration,
            error: .transport("current socket")
        )
        let currentCount = await hub.publishedFailureCountForTestingValue()
        XCTAssertEqual(currentCount, 1)
    }
}

final class RelayV2CommandOutboxTests: XCTestCase {
    private struct DrainFixture {
        let keyStore: RelayV2KeychainStore
        let identity: RelayV2Identity
        let database: RelayV2Database
        let repository: WorkRepository
        let client: RelayV2Client
    }

    private func makeDrainFixture(
        accountID: String,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws -> DrainFixture {
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.command-drain.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        var identity = RelayV2Identity.makeUnpaired(accountID: accountID)
        let deviceKeys = try XCTUnwrap(identity.currentKeys)
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = RelayV2Crypto.generateAgreementKeyPair().publicKey
        identity.agentSigningPublicKey = RelayV2Crypto.generateSigningKeyPair().publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        let repository = try WorkRepository(configuration: .init(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-v2-command-drain-\(UUID().uuidString)")
        ))
        let configuration: URLSessionConfiguration
        if let sessionConfiguration {
            configuration = sessionConfiguration
        } else {
            configuration = .ephemeral
            configuration.protocolClasses = [RelayV2HubAcceptStub.self]
            RelayV2HubAcceptStub.reset()
        }
        let database = try RelayV2Database.inMemory()
        let client = try RelayV2Client(
            identity: identity, keyStore: keyStore, database: database,
            hub: RelayV2HubTransport(
                configuration: try .init(
                    baseURL: URL(string: "https://relay.example.test")!,
                    routeID: "rte_device",
                    routeSigningPrivateKey: deviceKeys.signingPrivateKey
                ),
                session: URLSession(configuration: configuration),
                readinessProbeForTesting: {}
            ),
            workRepository: repository
        )
        return DrainFixture(
            keyStore: keyStore,
            identity: identity,
            database: database,
            repository: repository,
            client: client
        )
    }

    func testGeneratedClientMessageIDIsCanonicalLowercaseUUID() throws {
        let generated = RelayV2Identifiers.canonicalUUID()
        XCTAssertEqual(generated, generated.lowercased())
        XCTAssertEqual(generated.count, 36)
        XCTAssertEqual(UUID(uuidString: generated)?.uuidString.lowercased(), generated)
        XCTAssertTrue(generated.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil)

        let stable = RelayV2Identifiers.stableCanonicalUUID(seed: Data("approval".utf8))
        XCTAssertEqual(stable, RelayV2Identifiers.stableCanonicalUUID(seed: Data("approval".utf8)))
        XCTAssertEqual(UUID(uuidString: stable)?.uuidString.lowercased(), stable)
    }

    func testCacheNamespaceIsStableNonSecretAndAccountIsolated() {
        let first = RelayV2Identifiers.cacheNamespace(accountID: "acc_first")
        XCTAssertEqual(first, RelayV2Identifiers.cacheNamespace(accountID: "acc_first"))
        XCTAssertNotEqual(first, RelayV2Identifiers.cacheNamespace(accountID: "acc_second"))
        XCTAssertTrue(first.hasPrefix("relay-v2:"))
        XCTAssertFalse(first.contains("acc_first"))
    }

    func testSessionAdapterUsesRatifiedRPCMethods() throws {
        for (kind, method) in [
            (RelayV2CommandKind.sessionList, "session.list"),
            (.sessionHistory, "session.history"),
            (.sessionOpen, "session.open"),
            (.sessionResume, "session.resume"),
            (.clarify, "clarify.respond"),
            (.presenceSet, "presence.set"),
        ] {
            let request = try RelayV2RPCRequestFactory.make(
                kind: kind,
                operationID: "op_test",
                clientMessageID: "msg_test",
                params: [:]
            )
            XCTAssertEqual(request["method"]?.stringValue, method)
        }
    }

    func testFreshCommandOutboxAcceptsEveryRatifiedKindInEnqueueOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-v2-kinds-fresh-\(UUID().uuidString)")
        let repository = try WorkRepository(configuration: .init(containerURL: directory))
        let sameInstant = Date(timeIntervalSince1970: 1_000)
        for (index, kind) in RelayV2CommandKind.allCases.enumerated() {
            _ = try await repository.enqueueRelayV2Command(
                operationID: "op_\(RelayV2CommandKind.allCases.count - index)",
                clientMessageID: "msg_\(index)",
                accountID: "acc", sessionID: nil, kind: kind, payload: [:],
                now: sameInstant
            )
        }
        let stored = try await repository.relayV2Commands(accountID: "acc")
        XCTAssertEqual(stored.map(\.kind), RelayV2CommandKind.allCases)
        for expected in RelayV2CommandKind.allCases {
            let claimed = try await repository.claimRelayV2Command(
                accountID: "acc", owner: "owner_\(expected.rawValue)", now: sameInstant
            )
            XCTAssertEqual(claimed?.kind, expected)
            if let claimed {
                try await repository.markRelayV2Command(
                    operationID: claimed.operationID,
                    state: .completed,
                    onlyIfCurrentState: .sending,
                    now: sameInstant
                )
            }
        }
    }

    func testV4CommandOutboxUpgradePreservesRowsAndWidensKindConstraint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-v2-kinds-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let configuration = WorkRepositoryConfiguration(containerURL: directory)
        do {
            let queue = try DatabaseQueue(path: configuration.databaseURL.path)
            try WorkSchema.makeMigrator().migrate(
                queue, upTo: "work-v4-relay-v2-stable-envelope"
            )
            try await queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO relay_v2_commands(
                            op_id,client_message_id,account_id,session_id,kind,payload_json,
                            payload_hash,state,attempt_count,next_attempt_at,lease_owner,
                            lease_expires_at,last_error_code,created_at,updated_at,completed_at,
                            fixed_expires_at,envelope_json
                        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """,
                    arguments: [
                        "op_existing", "msg_existing", "acc", nil, "prompt", Data("{}".utf8),
                        "hash", "queued", 0, nil, nil, nil, nil, 1.0, 1.0, nil, 86_401.0, nil,
                    ]
                )
            }
        }
        let repository = try WorkRepository(configuration: configuration)
        for (index, kind) in RelayV2CommandKind.allCases.enumerated() where kind != .prompt {
            _ = try await repository.enqueueRelayV2Command(
                operationID: "op_new_\(index)", clientMessageID: "msg_new_\(index)",
                accountID: "acc", sessionID: nil, kind: kind, payload: [:]
            )
        }
        let stored = try await repository.relayV2Commands(accountID: "acc")
        XCTAssertEqual(stored.first?.operationID, "op_existing")
        XCTAssertEqual(Set(stored.map(\.kind)), Set(RelayV2CommandKind.allCases))
    }

    func testStableOperationAndClientMessageIDsAreDurableAndConflictChecked() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-v2-work-\(UUID().uuidString)")
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory)
        )
        let first = try await repository.enqueueRelayV2Command(
            operationID: "op_stable", clientMessageID: "msg_stable",
            accountID: "acc_test", sessionID: "s", kind: .approval,
            payload: ["request_id": "req", "decision": "approve_once"]
        )
        let request = try XCTUnwrap(
            try JSONDecoder().decode(JSONValue.self, from: first.payloadJSON).objectValue
        )
        XCTAssertEqual(Set(request.keys), ["jsonrpc", "id", "method", "params", "op_id"])
        XCTAssertEqual(request["jsonrpc"]?.stringValue, "2.0")
        XCTAssertEqual(request["method"]?.stringValue, "approval.respond")
        XCTAssertEqual(request["op_id"]?.stringValue, "op_stable")
        XCTAssertEqual(request["params"]?.objectValue?["decision"]?.stringValue, "approve_once")
        let duplicate = try await repository.enqueueRelayV2Command(
            operationID: "op_stable", clientMessageID: "msg_stable",
            accountID: "acc_test", sessionID: "s", kind: .approval,
            payload: ["request_id": "req", "decision": "approve_once"]
        )
        XCTAssertEqual(first, duplicate)
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.enqueueRelayV2Command(
                operationID: "op_stable", clientMessageID: "msg_stable",
                accountID: "acc_test", sessionID: "s", kind: .approval,
                payload: ["request_id": "req", "decision": "deny"]
            )
        }
        let claimed = try await repository.claimRelayV2Command(accountID: "acc_test", owner: "worker")
        XCTAssertEqual(claimed?.operationID, "op_stable")
        XCTAssertEqual(claimed?.clientMessageID, "msg_stable")

        let beforeLeaseExpiry = try await repository.claimRelayV2Command(
            accountID: "acc_test", owner: "worker-2", now: Date(timeIntervalSince1970: first.createdAt + 5)
        )
        XCTAssertNil(beforeLeaseExpiry)
        let reclaimed = try await repository.claimRelayV2Command(
            accountID: "acc_test", owner: "worker-2", now: Date(timeIntervalSince1970: first.createdAt + 31)
        )
        XCTAssertEqual(reclaimed?.operationID, "op_stable")

        let header = try RelayV2OuterHeader(
            source: "rte_device", destination: "rte_agent",
            messageID: RelayV2Wire.base64URL(Data(repeating: 7, count: 16)),
            messageClass: .command,
            expiresAtMilliseconds: UInt64((try XCTUnwrap(first.fixedExpiresAt)) * 1_000),
            recipientKeyGeneration: 1
        )
        let original = try RelayV2OuterEnvelope(
            header: header, encapsulatedKey: Data(repeating: 1, count: 32),
            ciphertext: Data(repeating: 2, count: 16), signature: Data(repeating: 3, count: 64)
        )
        let replacement = try RelayV2OuterEnvelope(
            header: header, encapsulatedKey: Data(repeating: 4, count: 32),
            ciphertext: Data(repeating: 5, count: 16), signature: Data(repeating: 6, count: 64)
        )
        _ = try await repository.persistRelayV2Envelope(operationID: "op_stable", envelope: original)
        let retried = try await repository.persistRelayV2Envelope(
            operationID: "op_stable", envelope: replacement
        )
        XCTAssertEqual(try retried.canonicalJSON(), try original.canonicalJSON())
    }

    func testReceiptErrorsClassifyRetryAmbiguousAndTerminalStates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-v2-receipts-\(UUID().uuidString)")
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory)
        )
        for (suffix, code, expected) in [
            ("offline", RelayV2ErrorCode.gatewayOffline, RelayV2CommandState.completed),
            ("ambiguous", .gatewayAmbiguous, .ambiguous),
            ("expired", .expired, .expired),
            ("revoked", .revoked, .completed),
        ] {
            let record = try await repository.enqueueRelayV2Command(
                operationID: "op_\(suffix)", clientMessageID: "msg_\(suffix)",
                accountID: "acc", sessionID: nil, kind: .interrupt, payload: [:]
            )
            try await repository.markRelayV2Command(operationID: record.operationID, state: .accepted)
            try await repository.resolveRelayV2Command(
                accountID: "acc", clientMessageID: record.clientMessageID, errorCode: code
            )
            let resolved = try await repository.relayV2Commands(accountID: "acc")
                .first { $0.operationID == record.operationID }
            XCTAssertEqual(resolved?.state, expected)
            XCTAssertEqual(resolved?.lastErrorCode, code.rawValue)
        }
        let replay = try await repository.claimRelayV2Command(
            accountID: "acc", owner: "must-not-replay"
        )
        XCTAssertNil(replay)
    }

    func testPostCompletionCASCannotRegressCommandBackToAccepted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-v2-race-\(UUID().uuidString)")
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory)
        )
        let record = try await repository.enqueueRelayV2Command(
            operationID: "op_race", clientMessageID: "msg_race",
            accountID: "acc", sessionID: "s", kind: .prompt, payload: ["text": "hello"]
        )
        _ = try await repository.claimRelayV2Command(accountID: "acc", owner: "sender")
        try await repository.resolveRelayV2Command(
            accountID: "acc", clientMessageID: record.clientMessageID
        )
        let changed = try await repository.markRelayV2Command(
            operationID: record.operationID,
            state: .accepted,
            onlyIfCurrentState: .sending
        )
        XCTAssertFalse(changed)
        let commands = try await repository.relayV2Commands(accountID: "acc")
        XCTAssertEqual(commands.first?.state, .completed)
    }

    func testConcurrentDrainsRemainSingleFlightAndPreserveFIFO() async throws {
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.command-order.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        var identity = RelayV2Identity.makeUnpaired(accountID: "acc_order")
        let deviceKeys = try XCTUnwrap(identity.currentKeys)
        let agent = RelayV2Crypto.generateAgreementKeyPair()
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = agent.publicKey
        identity.agentSigningPublicKey = RelayV2Crypto.generateSigningKeyPair().publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        let repository = try WorkRepository(configuration: .init(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-v2-command-order-\(UUID().uuidString)")
        ))
        let now = Date()
        _ = try await repository.enqueueRelayV2Command(
            operationID: "op_z_prompt", clientMessageID: "msg_prompt",
            accountID: identity.accountID, sessionID: "session", kind: .prompt,
            payload: ["text": "hello"], now: now
        )
        _ = try await repository.enqueueRelayV2Command(
            operationID: "op_a_interrupt", clientMessageID: "msg_interrupt",
            accountID: identity.accountID, sessionID: "session", kind: .interrupt,
            payload: ["session_id": "session"], now: now
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayV2HubAcceptStub.self]
        RelayV2HubAcceptStub.reset()
        RelayV2HubAcceptStub.responseDelay = 0.05
        let client = try RelayV2Client(
            identity: identity, keyStore: keyStore, database: .inMemory(),
            hub: RelayV2HubTransport(
                configuration: try .init(
                    baseURL: URL(string: "https://relay.example.test")!,
                    routeID: "rte_device",
                    routeSigningPrivateKey: deviceKeys.signingPrivateKey
                ),
                session: URLSession(configuration: configuration)
            ),
            workRepository: repository
        )
        async let firstDrain: Void = client.drainCommands(repository: repository, owner: "one")
        async let secondDrain: Void = client.drainCommands(repository: repository, owner: "two")
        _ = await (firstDrain, secondDrain)

        let receive = RelayV2ReceiveContext(
            expectedDestination: "rte_agent", expectedSource: "rte_device",
            nowMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000),
            seenMessageIDs: []
        )
        let methods = try RelayV2HubAcceptStub.postedBodies.map { body -> String in
            let envelope = try RelayV2OuterEnvelope.decodeStrict(from: body)
            let message = try RelayV2Crypto.openAuthenticatedEnvelope(
                envelope, recipientPrivateKeys: [1: agent.privateKey],
                senderAgreementPublicKey: try deviceKeys.agreementPublicKey,
                senderSigningPublicKey: try deviceKeys.signingPublicKey,
                expectedSenderKeyGeneration: 1, purpose: .chat,
                direction: .deviceToAgent, receive: receive
            )
            return try XCTUnwrap(message.body["method"]?.stringValue)
        }
        XCTAssertEqual(methods, ["prompt.submit", "session.interrupt"])
        XCTAssertEqual(RelayV2HubAcceptStub.maximumConcurrentPosts, 1)
        keyStore.deleteIdentity(accountID: identity.accountID)
    }

    func testConcurrentEnqueueAtEmptyDrainTailCannotLoseWakeup() async throws {
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.command-tail-wakeup.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        var identity = RelayV2Identity.makeUnpaired(accountID: "acc_tail_wakeup")
        let deviceKeys = try XCTUnwrap(identity.currentKeys)
        let agent = RelayV2Crypto.generateAgreementKeyPair()
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = agent.publicKey
        identity.agentSigningPublicKey = RelayV2Crypto.generateSigningKeyPair().publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        let repository = try WorkRepository(configuration: .init(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-v2-command-tail-wakeup-\(UUID().uuidString)")
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayV2HubAcceptStub.self]
        RelayV2HubAcceptStub.reset()
        let client = try RelayV2Client(
            identity: identity, keyStore: keyStore, database: .inMemory(),
            hub: RelayV2HubTransport(
                configuration: try .init(
                    baseURL: URL(string: "https://relay.example.test")!,
                    routeID: "rte_device",
                    routeSigningPrivateKey: deviceKeys.signingPrivateKey
                ),
                session: URLSession(configuration: configuration)
            ),
            workRepository: repository
        )
        let gate = RelayV2DrainEmptyTailGate()
        await client.setCommandDrainEmptyTailHookForTesting {
            await gate.pauseFirstEmptyClaim()
        }

        let activeDrain = Task {
            await client.drainCommands(repository: repository, owner: "active")
        }
        await gate.waitUntilPaused()
        _ = try await repository.enqueueRelayV2Command(
            operationID: "op_tail", clientMessageID: "msg_tail",
            accountID: identity.accountID, sessionID: "session", kind: .interrupt,
            payload: ["session_id": "session"]
        )
        // This invocation deterministically reaches the client while the first
        // owner is paused after observing an empty queue. The old Boolean-only
        // guard returned here and then let the owner exit, stranding op_tail.
        await client.drainCommands(repository: repository, owner: "overlap")
        await gate.release()
        await activeDrain.value
        await client.setCommandDrainEmptyTailHookForTesting(nil)

        XCTAssertEqual(RelayV2HubAcceptStub.postedBodies.count, 1)
        let commands = try await repository.relayV2Commands(accountID: identity.accountID)
        XCTAssertEqual(commands.map(\.operationID), ["op_tail"])
        XCTAssertEqual(commands.map(\.state), [.accepted])
        keyStore.deleteIdentity(accountID: identity.accountID)
    }

    func testCancelledOwnerHandsAdvancedDemandToFreshDrain() async throws {
        let fixture = try makeDrainFixture(accountID: "acc_cancel_handoff")
        let gate = RelayV2DrainEmptyTailGate()
        await fixture.client.setCommandDrainEmptyTailHookForTesting {
            await gate.pauseFirstEmptyClaim()
        }
        let activeDrain = Task {
            await fixture.client.drainCommands(
                repository: fixture.repository,
                owner: "cancelled-owner"
            )
        }
        await gate.waitUntilPaused()
        await fixture.client.cancelCommandDrainTaskForTesting()
        _ = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_after_cancel", clientMessageID: "msg_after_cancel",
            accountID: fixture.identity.accountID, sessionID: "session",
            kind: .interrupt, payload: ["session_id": "session"]
        )
        await fixture.client.drainCommands(
            repository: fixture.repository,
            owner: "overlap"
        )
        await gate.release()
        await activeDrain.value
        await fixture.client.waitForCommandDrainIdleForTesting()
        await fixture.client.setCommandDrainEmptyTailHookForTesting(nil)

        XCTAssertEqual(RelayV2HubAcceptStub.postedBodies.count, 1)
        let commands = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(commands.map(\.operationID), ["op_after_cancel"])
        XCTAssertEqual(commands.map(\.state), [.accepted])
        fixture.keyStore.deleteIdentity(accountID: fixture.identity.accountID)
    }

    func testClaimFailureHandsAdvancedDemandToFreshDrainWithoutSpin() async throws {
        let fixture = try makeDrainFixture(accountID: "acc_claim_handoff")
        let gate = RelayV2DrainClaimFailureGate()
        await fixture.client.setCommandDrainBeforeClaimHookForTesting {
            try await gate.failFirstClaimAfterRelease()
        }
        let activeDrain = Task {
            await fixture.client.drainCommands(
                repository: fixture.repository,
                owner: "failing-owner"
            )
        }
        await gate.waitUntilPaused()
        _ = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_after_claim_failure", clientMessageID: "msg_after_claim_failure",
            accountID: fixture.identity.accountID, sessionID: "session",
            kind: .interrupt, payload: ["session_id": "session"]
        )
        await fixture.client.drainCommands(
            repository: fixture.repository,
            owner: "overlap"
        )
        await gate.release()
        await activeDrain.value
        await fixture.client.waitForCommandDrainIdleForTesting()
        await fixture.client.setCommandDrainBeforeClaimHookForTesting(nil)

        let claimInvocations = await gate.invocationCount()
        XCTAssertEqual(claimInvocations, 3)
        XCTAssertEqual(RelayV2HubAcceptStub.postedBodies.count, 1)
        let commands = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(commands.map(\.operationID), ["op_after_claim_failure"])
        XCTAssertEqual(commands.map(\.state), [.accepted])
        fixture.keyStore.deleteIdentity(accountID: fixture.identity.accountID)
    }

    func testRetryableExitHandsAdvancedDemandOffAndHonorsBackoff() async throws {
        let fixture = try makeDrainFixture(accountID: "acc_retry_handoff")
        _ = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_retry_first", clientMessageID: "msg_retry_first",
            accountID: fixture.identity.accountID, sessionID: "session",
            kind: .interrupt, payload: ["session_id": "session"]
        )
        let gate = RelayV2DrainSendGate(mode: .retryable)
        await fixture.client.setCommandDrainSendHookForTesting { command in
            try await gate.send(command)
        }
        let activeDrain = Task {
            await fixture.client.drainCommands(
                repository: fixture.repository,
                owner: "retry-owner"
            )
        }
        await gate.waitUntilPaused()
        _ = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_retry_second", clientMessageID: "msg_retry_second",
            accountID: fixture.identity.accountID, sessionID: "session",
            kind: .interrupt, payload: ["session_id": "session"]
        )
        await fixture.client.drainCommands(
            repository: fixture.repository,
            owner: "overlap"
        )
        await gate.release()
        await activeDrain.value
        await fixture.client.waitForCommandDrainIdleForTesting()
        await fixture.client.setCommandDrainSendHookForTesting(nil)

        let retryInvocations = await gate.invocationCount()
        XCTAssertEqual(retryInvocations, 2)
        let commands = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(commands.map(\.operationID), ["op_retry_first", "op_retry_second"])
        XCTAssertEqual(commands.map(\.state), [.retryWait, .retryWait])
        XCTAssertTrue(commands.allSatisfy { $0.nextAttemptAt != nil })
        fixture.keyStore.deleteIdentity(accountID: fixture.identity.accountID)
    }

    func testGenericErrorExitHandsAdvancedDemandToFreshDrain() async throws {
        let fixture = try makeDrainFixture(accountID: "acc_generic_handoff")
        _ = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_generic_first", clientMessageID: "msg_generic_first",
            accountID: fixture.identity.accountID, sessionID: "session",
            kind: .interrupt, payload: ["session_id": "session"]
        )
        let gate = RelayV2DrainSendGate(mode: .genericThenAccept)
        await fixture.client.setCommandDrainSendHookForTesting { command in
            try await gate.send(command)
        }
        let activeDrain = Task {
            await fixture.client.drainCommands(
                repository: fixture.repository,
                owner: "generic-owner"
            )
        }
        await gate.waitUntilPaused()
        _ = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_generic_second", clientMessageID: "msg_generic_second",
            accountID: fixture.identity.accountID, sessionID: "session",
            kind: .interrupt, payload: ["session_id": "session"]
        )
        await fixture.client.drainCommands(
            repository: fixture.repository,
            owner: "overlap"
        )
        await gate.release()
        await activeDrain.value
        await fixture.client.waitForCommandDrainIdleForTesting()
        await fixture.client.setCommandDrainSendHookForTesting(nil)

        let genericInvocations = await gate.invocationCount()
        XCTAssertEqual(genericInvocations, 2)
        let commands = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(commands.map(\.operationID), ["op_generic_first", "op_generic_second"])
        XCTAssertEqual(commands.map(\.state), [.ambiguous, .accepted])
        XCTAssertNotNil(commands.first?.nextAttemptAt)
        fixture.keyStore.deleteIdentity(accountID: fixture.identity.accountID)
    }

    func testRetryAndAmbiguousDeadlinesWakeWithoutExternalDemand() async throws {
        for (suffix, outcome, expectedInitialState) in [
            ("retry", RelayV2AutomaticRetryGate.Outcome.retryWait, RelayV2CommandState.retryWait),
            ("ambiguous", .ambiguous, .ambiguous),
        ] {
            let fixture = try makeDrainFixture(accountID: "acc_automatic_\(suffix)")
            _ = try await fixture.repository.enqueueRelayV2Command(
                operationID: "op_automatic_\(suffix)",
                clientMessageID: "msg_automatic_\(suffix)",
                accountID: fixture.identity.accountID, sessionID: "session",
                kind: .interrupt, payload: ["session_id": "session"]
            )
            let gate = RelayV2AutomaticRetryGate(outcome: outcome)
            await fixture.client.setCommandDrainSendHookForTesting { command in
                try await gate.send(command)
            }

            // This is the only explicit wake. The second attempt must come
            // solely from the persisted nextAttemptAt deadline.
            await fixture.client.drainCommands(
                repository: fixture.repository,
                owner: "initial-\(suffix)"
            )
            let initial = try await fixture.repository.relayV2Commands(
                accountID: fixture.identity.accountID
            )
            XCTAssertEqual(initial.map(\.state), [expectedInitialState])
            XCTAssertNotNil(initial.first?.nextAttemptAt)
            let armed = await fixture.client.connectionLifecycleSnapshotForTesting()
            XCTAssertTrue(armed.commandRetryTimerActive)

            await gate.waitUntilSecondSend()
            await fixture.client.waitForCommandDrainIdleForTesting()
            let recovered = try await fixture.repository.relayV2Commands(
                accountID: fixture.identity.accountID
            )
            XCTAssertEqual(recovered.map(\.state), [.accepted])
            let invocationCount = await gate.invocationCount()
            XCTAssertEqual(invocationCount, 2)
            let completed = await fixture.client.connectionLifecycleSnapshotForTesting()
            XCTAssertFalse(completed.commandRetryTimerActive)

            await fixture.client.setCommandDrainSendHookForTesting(nil)
            await fixture.client.disconnect()
            fixture.keyStore.deleteIdentity(accountID: fixture.identity.accountID)
        }
    }

    func testDeadlineReadFailureKeepsOwnedWakeAndRecoversWithoutExternalDemand() async throws {
        let fixture = try makeDrainFixture(accountID: "acc_deadline_read_recovery")
        _ = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_deadline_read_recovery",
            clientMessageID: "msg_deadline_read_recovery",
            accountID: fixture.identity.accountID,
            sessionID: "session",
            kind: .interrupt,
            payload: ["session_id": "session"]
        )
        _ = try await fixture.repository.claimRelayV2Command(
            accountID: fixture.identity.accountID,
            owner: "crashed-owner",
            leaseDuration: 0.15
        )
        let gate = RelayV2DeadlineReadFailureGate(
            repository: fixture.repository,
            accountID: fixture.identity.accountID
        )
        await fixture.client.setCommandWakeDeadlineLoadHookForTesting {
            try await gate.load()
        }

        // This is the only explicit wake. The first deadline discovery fails,
        // so the client must retain a bounded owned wake and recover itself.
        await fixture.client.drainCommands(
            repository: fixture.repository,
            owner: "deadline-read-observer"
        )
        await fixture.client.waitForCommandDrainIdleForTesting()
        let armed = await fixture.client.connectionLifecycleSnapshotForTesting()
        XCTAssertTrue(armed.commandRetryTimerActive)

        await gate.waitUntilRecoveryRead()
        await fixture.client.waitForCommandDrainIdleForTesting()
        let recovered = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(recovered.map(\.state), [.accepted])
        XCTAssertEqual(RelayV2HubAcceptStub.postedBodies.count, 1)
        let readCount = await gate.invocationCount()
        XCTAssertGreaterThanOrEqual(readCount, 2)
        let completed = await fixture.client.connectionLifecycleSnapshotForTesting()
        XCTAssertFalse(completed.commandRetryTimerActive)

        await fixture.client.setCommandWakeDeadlineLoadHookForTesting(nil)
        await fixture.client.disconnect()
        fixture.keyStore.deleteIdentity(accountID: fixture.identity.accountID)
    }

    func testDisconnectCancelsLeaseTimerUntilFreshConnectRecovers() async throws {
        let fixture = try makeDrainFixture(accountID: "acc_lease_timer")
        _ = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_leased", clientMessageID: "msg_leased",
            accountID: fixture.identity.accountID, sessionID: "session",
            kind: .interrupt, payload: ["session_id": "session"]
        )
        _ = try await fixture.repository.claimRelayV2Command(
            accountID: fixture.identity.accountID,
            owner: "crashed-owner",
            leaseDuration: 0.15
        )
        await fixture.client.drainCommands(
            repository: fixture.repository,
            owner: "lease-observer"
        )
        let armed = await fixture.client.connectionLifecycleSnapshotForTesting()
        XCTAssertTrue(armed.commandRetryTimerActive)

        await fixture.client.disconnect()
        let disconnected = await fixture.client.connectionLifecycleSnapshotForTesting()
        XCTAssertFalse(disconnected.commandRetryTimerActive)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(RelayV2HubAcceptStub.postedBodies.count, 0)

        try await fixture.client.connect()
        await fixture.client.waitForCommandDrainIdleForTesting()
        XCTAssertEqual(RelayV2HubAcceptStub.postedBodies.count, 1)
        let recovered = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(recovered.map(\.state), [.accepted])

        await fixture.client.disconnect()
        fixture.keyStore.deleteIdentity(accountID: fixture.identity.accountID)
    }

    func testRevokedPostFencesLaterCommandsAndTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayV2RevokedThenAcceptStub.self]
        RelayV2RevokedThenAcceptStub.reset()
        let fixture = try makeDrainFixture(
            accountID: "acc_revoked_fence",
            sessionConfiguration: configuration
        )
        for suffix in ["first", "must_not_post"] {
            _ = try await fixture.repository.enqueueRelayV2Command(
                operationID: "op_\(suffix)", clientMessageID: "msg_\(suffix)",
                accountID: fixture.identity.accountID, sessionID: "session",
                kind: .interrupt, payload: ["session_id": "session"]
            )
        }

        await fixture.client.drainCommands(
            repository: fixture.repository,
            owner: "revoked-owner"
        )
        await fixture.client.waitForCommandDrainIdleForTesting()

        XCTAssertEqual(RelayV2RevokedThenAcceptStub.postCount, 1)
        let commands = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(commands.map(\.state), [.completed, .queued])
        XCTAssertEqual(commands.first?.lastErrorCode, RelayV2ErrorCode.revoked.rawValue)
        XCTAssertNil(try fixture.keyStore.loadIdentity(accountID: fixture.identity.accountID))
        let lifecycle = await fixture.client.connectionLifecycleSnapshotForTesting()
        XCTAssertFalse(lifecycle.commandDrainAcceptingWakeups)
        XCTAssertFalse(lifecycle.commandRetryTimerActive)
        let failedState = await fixture.client.state
        guard case .failed = failedState else {
            return XCTFail("Expected revoked transport to fail closed")
        }

        await fixture.client.disconnect()
        await XCTAssertThrowsErrorAsync {
            try await fixture.client.connect()
        }
        XCTAssertEqual(RelayV2RevokedThenAcceptStub.postCount, 1)
    }

    func testHTTPRevokedCrashBoundaryPersistsBeforeCommandMarker() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayV2RevokedThenAcceptStub.self]
        RelayV2RevokedThenAcceptStub.reset()
        let fixture = try makeDrainFixture(
            accountID: "acc_http_revoke_crash",
            sessionConfiguration: configuration
        )
        _ = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_http_revoke",
            clientMessageID: "msg_http_revoke",
            accountID: fixture.identity.accountID,
            sessionID: "session",
            kind: .interrupt,
            payload: ["session_id": "session"]
        )
        await fixture.client.setRevocationAfterTombstoneHookForTesting { source in
            source == "command_http"
        }

        await fixture.client.drainCommands(
            repository: fixture.repository,
            owner: "http-revoke-crash"
        )
        await fixture.client.waitForCommandDrainIdleForTesting()

        let tombstone = try await fixture.database.accountRevocation(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(tombstone?.source, "command_http")
        let commands = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(commands.map(\.state), [.sending])
        XCTAssertNil(commands.first?.lastErrorCode)
        XCTAssertNotNil(try fixture.keyStore.loadIdentity(accountID: fixture.identity.accountID))
        XCTAssertEqual(RelayV2RevokedThenAcceptStub.postCount, 1)

        let deviceKeys = try XCTUnwrap(fixture.identity.currentKeys)
        let restarted = try RelayV2Client(
            identity: fixture.identity,
            keyStore: fixture.keyStore,
            database: fixture.database,
            hub: RelayV2HubTransport(
                configuration: try .init(
                    baseURL: URL(string: "https://relay.example.test")!,
                    routeID: "rte_device",
                    routeSigningPrivateKey: deviceKeys.signingPrivateKey
                ),
                session: URLSession(configuration: configuration),
                readinessProbeForTesting: {}
            ),
            workRepository: fixture.repository
        )
        await XCTAssertThrowsErrorAsync { try await restarted.connect() }
        XCTAssertNil(try fixture.keyStore.loadIdentity(accountID: fixture.identity.accountID))
        XCTAssertEqual(RelayV2RevokedThenAcceptStub.postCount, 1)
    }

    func testDisconnectFencesOwnedHandoffBeforeReplacementReconnects() async throws {
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.command-lifecycle.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        var identity = RelayV2Identity.makeUnpaired(accountID: "acc_disconnect_handoff")
        let deviceKeys = try XCTUnwrap(identity.currentKeys)
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = RelayV2Crypto.generateAgreementKeyPair().publicKey
        identity.agentSigningPublicKey = RelayV2Crypto.generateSigningKeyPair().publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        let repository = try WorkRepository(configuration: .init(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-v2-command-lifecycle-\(UUID().uuidString)")
        ))
        let gate = RelayV2LifecyclePostGate()
        RelayV2LifecyclePostStub.reset(gate: gate)
        let makeClient = { () throws -> RelayV2Client in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RelayV2LifecyclePostStub.self]
            return try RelayV2Client(
                identity: identity, keyStore: keyStore, database: .inMemory(),
                hub: RelayV2HubTransport(
                    configuration: try .init(
                        baseURL: URL(string: "https://relay.example.test")!,
                        routeID: "rte_device",
                        routeSigningPrivateKey: deviceKeys.signingPrivateKey
                    ),
                    session: URLSession(configuration: configuration),
                    readinessProbeForTesting: {}
                ),
                workRepository: repository
            )
        }
        let oldClient = try makeClient()
        _ = try await repository.enqueueRelayV2Command(
            operationID: "op_in_flight", clientMessageID: "msg_in_flight",
            accountID: identity.accountID, sessionID: "session",
            kind: .interrupt, payload: ["session_id": "session"]
        )
        let oldDrain = Task {
            await oldClient.drainCommands(repository: repository, owner: "old-client")
        }
        await gate.waitUntilFirstPostStarted()

        _ = try await repository.enqueueRelayV2Command(
            operationID: "op_after_disconnect", clientMessageID: "msg_after_disconnect",
            accountID: identity.accountID, sessionID: "session",
            kind: .interrupt, payload: ["session_id": "session"]
        )
        // Advance demand while the first post is in flight. Without the
        // lifecycle epoch, the cancelled owner can hand this demand to an
        // untracked successor after disconnect begins.
        await oldClient.drainCommands(repository: repository, owner: "handoff-wake")
        await oldClient.disconnect()
        await oldDrain.value

        let afterDisconnect = RelayV2LifecyclePostStub.snapshot()
        XCTAssertEqual(afterDisconnect.posts, 1)
        XCTAssertEqual(afterDisconnect.activePosts, 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(RelayV2LifecyclePostStub.snapshot().posts, 1)

        // A replacement client sharing the durable outbox is allowed to wake
        // work only after the old client's disconnect fence has completed.
        let replacementClient = try makeClient()
        try await replacementClient.connect()
        await replacementClient.waitForCommandDrainIdleForTesting()

        let afterReconnect = RelayV2LifecyclePostStub.snapshot()
        XCTAssertEqual(afterReconnect.posts, 2)
        XCTAssertEqual(afterReconnect.activePosts, 0)
        XCTAssertEqual(afterReconnect.maximumConcurrentPosts, 1)
        let commands = try await repository.relayV2Commands(accountID: identity.accountID)
        XCTAssertEqual(commands.map(\.operationID), ["op_in_flight", "op_after_disconnect"])
        XCTAssertEqual(commands.map(\.state), [.ambiguous, .accepted])

        await replacementClient.disconnect()
        keyStore.deleteIdentity(accountID: identity.accountID)
    }

    func testDisconnectInvalidatesBlockedConnectBeforeItCanRearmOrDrain() async throws {
        let fixture = try makeDrainFixture(accountID: "acc_connect_lifecycle")
        _ = try await fixture.repository.enqueueRelayV2Command(
            operationID: "op_waiting_for_connect", clientMessageID: "msg_waiting_for_connect",
            accountID: fixture.identity.accountID, sessionID: "session",
            kind: .interrupt, payload: ["session_id": "session"]
        )
        let gate = RelayV2ConnectLifecycleGate()
        await fixture.client.setConnectionAfterHubConnectHookForTesting {
            await gate.pauseFirstConnection()
        }
        await fixture.client.setConnectionDidInvalidateHookForTesting {
            await gate.recordDisconnectInvalidated()
        }

        let staleConnect = Task {
            try await fixture.client.connect()
        }
        await gate.waitUntilConnectionPaused()
        let disconnect = Task {
            await fixture.client.disconnect()
        }
        await gate.waitUntilDisconnectInvalidated()
        let duplicateDisconnect = Task {
            await fixture.client.disconnect()
        }
        await gate.releaseConnection()
        await disconnect.value
        await duplicateDisconnect.value

        switch await staleConnect.result {
        case .success:
            XCTFail("The invalidated connection attempt unexpectedly succeeded")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        let disconnected = await fixture.client.connectionLifecycleSnapshotForTesting()
        XCTAssertFalse(disconnected.connectionAttemptActive)
        XCTAssertFalse(disconnected.receiveWorkerActive)
        XCTAssertFalse(disconnected.failureWorkerActive)
        XCTAssertFalse(disconnected.commandDrainAcceptingWakeups)
        let disconnectedState = await fixture.client.state
        XCTAssertEqual(disconnectedState, .idle)
        XCTAssertEqual(RelayV2HubAcceptStub.postedBodies.count, 0)

        // A wake issued after disconnect must remain closed until a genuinely
        // fresh connection attempt explicitly reopens the durable drain.
        await fixture.client.drainCommands(repository: fixture.repository, owner: "disconnected")
        XCTAssertEqual(RelayV2HubAcceptStub.postedBodies.count, 0)

        await fixture.client.setConnectionAfterHubConnectHookForTesting(nil)
        await fixture.client.setConnectionDidInvalidateHookForTesting(nil)
        try await fixture.client.connect()
        await fixture.client.waitForCommandDrainIdleForTesting()

        XCTAssertEqual(RelayV2HubAcceptStub.postedBodies.count, 1)
        let recovered = try await fixture.repository.relayV2Commands(
            accountID: fixture.identity.accountID
        )
        XCTAssertEqual(recovered.map(\.operationID), ["op_waiting_for_connect"])
        XCTAssertEqual(recovered.map(\.state), [.accepted])

        await fixture.client.disconnect()
        fixture.keyStore.deleteIdentity(accountID: fixture.identity.accountID)
    }

    func testRequestWaiterExistsBeforeImmediateAuthenticatedResponse() async throws {
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.request-race.\(UUID().uuidString)", previewAccessGroup: nil
        )
        var identity = RelayV2Identity.makeUnpaired(accountID: "acc_request_race")
        let deviceKeys = try XCTUnwrap(identity.currentKeys)
        let agent = RelayV2Crypto.generateAgreementKeyPair()
        let agentSigning = RelayV2Crypto.generateSigningKeyPair()
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = agent.publicKey
        identity.agentSigningPublicKey = agentSigning.publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        let repository = try WorkRepository(configuration: .init(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-v2-request-race-\(UUID().uuidString)")
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayV2HubAcceptStub.self]
        RelayV2HubAcceptStub.reset()
        RelayV2HubAcceptStub.responseDelay = 0.1
        let client = try RelayV2Client(
            identity: identity, keyStore: keyStore, database: .inMemory(),
            hub: RelayV2HubTransport(
                configuration: try .init(
                    baseURL: URL(string: "https://relay.example.test")!,
                    routeID: "rte_device", routeSigningPrivateKey: deviceKeys.signingPrivateKey
                ),
                session: URLSession(configuration: configuration)
            ),
            workRepository: repository
        )
        RelayV2HubAcceptStub.onPost = { envelope in
            guard envelope.header.messageClass == .command else { return }
            Task {
                do {
                    let outbound = try RelayV2Crypto.openAuthenticatedEnvelope(
                        envelope, recipientPrivateKeys: [1: agent.privateKey],
                        senderAgreementPublicKey: try deviceKeys.agreementPublicKey,
                        senderSigningPublicKey: try deviceKeys.signingPublicKey,
                        expectedSenderKeyGeneration: 1, purpose: .chat,
                        direction: .deviceToAgent,
                        receive: .init(
                            expectedDestination: "rte_agent", expectedSource: "rte_device",
                            nowMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000),
                            seenMessageIDs: []
                        )
                    )
                    guard let requestID = outbound.body["id"]?.stringValue else { return }
                    let now = UInt64(Date().timeIntervalSince1970 * 1_000)
                    let response = try RelayV2SecureMessage(
                        messageID: RelayV2Wire.randomMessageID(), kind: .rpcResponse,
                        senderKeyGeneration: 1, createdAtMilliseconds: now,
                        expiresAtMilliseconds: now + 60_000,
                        body: [
                            "jsonrpc": "2.0", "id": .string(requestID),
                            "result": ["ok": true],
                        ]
                    )
                    let inbound = try RelayV2Crypto.sealAuthenticatedEnvelope(
                        header: RelayV2OuterHeader(
                            source: "rte_agent", destination: "rte_device",
                            messageID: response.messageID, messageClass: .control,
                            expiresAtMilliseconds: response.expiresAtMilliseconds,
                            recipientKeyGeneration: 1
                        ),
                        message: response,
                        recipientPublicKey: try deviceKeys.agreementPublicKey,
                        senderAgreementPrivateKey: agent.privateKey,
                        senderSigningPrivateKey: agentSigning.privateKey,
                        purpose: .control,
                        direction: .agentToDevice
                    )
                    try await client.ingest(inbound)
                } catch {
                    // The request timeout below turns any callback failure into
                    // a deterministic test failure without crossing XCTest
                    // state from this concurrent callback.
                }
            }
        }
        let result = try await client.request(
            kind: .sessionList, params: [:], timeout: .seconds(2)
        )
        XCTAssertEqual(result["ok"]?.boolValue, true)
        RelayV2HubAcceptStub.onPost = nil
        try? await Task.sleep(for: .milliseconds(250))
        keyStore.deleteIdentity(accountID: identity.accountID)
    }

    func testApprovalCapabilityAndAllowedDecisionAreRequiredBeforeQueueOpen() async {
        await XCTAssertThrowsErrorAsync {
            try await RelayV2NotificationActionQueue.enqueueApproval(
                accountID: "acc", sessionID: "s", requestID: "r", approve: true,
                capability: "not a capability", allowedDecisions: ["approve_once"],
                deviceID: nil, deviceKeyGeneration: nil,
                operationID: nil, clientMessageID: nil
            )
        }
        await XCTAssertThrowsErrorAsync {
            try await RelayV2NotificationActionQueue.enqueueApproval(
                accountID: "acc", sessionID: "s", requestID: "r", approve: true,
                capability: "cap_valid", allowedDecisions: ["deny"],
                deviceID: nil, deviceKeyGeneration: nil,
                operationID: nil, clientMessageID: nil
            )
        }
    }
}

private actor RelayV2DrainEmptyTailGate {
    private var paused = false
    private var released = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseFirstEmptyClaim() async {
        guard !paused else { return }
        paused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor RelayV2LifecyclePostGate {
    private var firstPostStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func recordFirstPostStarted() {
        guard !firstPostStarted else { return }
        firstPostStarted = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }

    func waitUntilFirstPostStarted() async {
        if firstPostStarted { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor RelayV2ConnectLifecycleGate {
    private var connectionPaused = false
    private var connectionReleased = false
    private var disconnectInvalidated = false
    private var connectionPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectionReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseFirstConnection() async {
        guard !connectionPaused else { return }
        connectionPaused = true
        let waiters = connectionPauseWaiters
        connectionPauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !connectionReleased else { return }
        await withCheckedContinuation { connectionReleaseWaiters.append($0) }
    }

    func waitUntilConnectionPaused() async {
        if connectionPaused { return }
        await withCheckedContinuation { connectionPauseWaiters.append($0) }
    }

    func recordDisconnectInvalidated() {
        guard !disconnectInvalidated else { return }
        disconnectInvalidated = true
        let waiters = disconnectWaiters
        disconnectWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilDisconnectInvalidated() async {
        if disconnectInvalidated { return }
        await withCheckedContinuation { disconnectWaiters.append($0) }
    }

    func releaseConnection() {
        guard !connectionReleased else { return }
        connectionReleased = true
        let waiters = connectionReleaseWaiters
        connectionReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor RelayV2AutomaticRetryGate {
    enum Outcome: Sendable {
        case retryWait
        case ambiguous
    }

    private let outcome: Outcome
    private var calls = 0
    private var secondSendWaiters: [CheckedContinuation<Void, Never>] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func send(_ command: RelayV2CommandRecord) async throws -> RelayV2HubAccepted {
        calls += 1
        if calls == 1 {
            switch outcome {
            case .retryWait:
                throw RelayV2ProtocolError.remote(
                    .gatewayOffline,
                    retryAfterSeconds: 0.15
                )
            case .ambiguous:
                throw RelayV2ProtocolError.remote(
                    .gatewayAmbiguous,
                    retryAfterSeconds: 0.15
                )
            }
        }
        let waiters = secondSendWaiters
        secondSendWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return RelayV2HubAccepted(
            accepted: true,
            deduplicated: false,
            stored: true,
            messageID: command.clientMessageID
        )
    }

    func waitUntilSecondSend() async {
        if calls >= 2 { return }
        await withCheckedContinuation { secondSendWaiters.append($0) }
    }

    func invocationCount() -> Int { calls }
}

private enum RelayV2DrainInjectedError: Error {
    case claimFailure
    case deadlineReadFailure
    case genericSendFailure
}

private actor RelayV2DeadlineReadFailureGate {
    private let repository: WorkRepository
    private let accountID: String
    private var calls = 0
    private var recoveryReadWaiters: [CheckedContinuation<Void, Never>] = []

    init(repository: WorkRepository, accountID: String) {
        self.repository = repository
        self.accountID = accountID
    }

    func load() async throws -> [RelayV2CommandRecord] {
        calls += 1
        if calls == 1 {
            throw RelayV2DrainInjectedError.deadlineReadFailure
        }
        let waiters = recoveryReadWaiters
        recoveryReadWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await repository.relayV2Commands(accountID: accountID)
    }

    func waitUntilRecoveryRead() async {
        if calls >= 2 { return }
        await withCheckedContinuation { recoveryReadWaiters.append($0) }
    }

    func invocationCount() -> Int { calls }
}

private actor RelayV2DrainClaimFailureGate {
    private var calls = 0
    private var paused = false
    private var released = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func failFirstClaimAfterRelease() async throws {
        calls += 1
        guard calls == 1 else { return }
        paused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        throw RelayV2DrainInjectedError.claimFailure
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func invocationCount() -> Int { calls }
}

private actor RelayV2DrainSendGate {
    enum Mode: Sendable {
        case retryable
        case genericThenAccept
    }

    private let mode: Mode
    private var calls = 0
    private var paused = false
    private var released = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(mode: Mode) { self.mode = mode }

    func send(_ command: RelayV2CommandRecord) async throws -> RelayV2HubAccepted {
        calls += 1
        if calls == 1 {
            paused = true
            let waiters = pauseWaiters
            pauseWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            switch mode {
            case .retryable:
                throw RelayV2ProtocolError.remote(
                    .gatewayOffline,
                    retryAfterSeconds: 30
                )
            case .genericThenAccept:
                throw RelayV2DrainInjectedError.genericSendFailure
            }
        }
        switch mode {
        case .retryable:
            throw RelayV2ProtocolError.remote(
                .gatewayOffline,
                retryAfterSeconds: 30
            )
        case .genericThenAccept:
            return RelayV2HubAccepted(
                accepted: true,
                deduplicated: false,
                stored: true,
                messageID: command.clientMessageID
            )
        }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func invocationCount() -> Int { calls }
}

private actor RelayV2PresenceCapture {
    private var values: [Bool] = []
    func append(_ value: Bool) { values.append(value) }
    func snapshot() -> [Bool] { values }
}

private enum RelayV2ConfigureInjectedError: Error {
    case afterAssignment
}

private actor RelayV2ConfigureAssignmentGate {
    private var calls = 0
    private var observedWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedCalls = Set<Int>()
    private var releaseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func pauseThenFail() async throws {
        calls += 1
        let call = calls
        let observers = observedWaiters.removeValue(forKey: call) ?? []
        observers.forEach { $0.resume() }
        if !releasedCalls.contains(call) {
            await withCheckedContinuation { continuation in
                releaseWaiters[call, default: []].append(continuation)
            }
        }
        throw RelayV2ConfigureInjectedError.afterAssignment
    }

    func waitUntilCall(_ call: Int) async {
        if calls >= call { return }
        await withCheckedContinuation { continuation in
            observedWaiters[call, default: []].append(continuation)
        }
    }

    func release(_ call: Int) {
        releasedCalls.insert(call)
        let waiters = releaseWaiters.removeValue(forKey: call) ?? []
        waiters.forEach { $0.resume() }
    }
}

@MainActor
private final class RelayV2SetupSequence {
    private var values: [(RelayV2Client, WorkRepository)]

    init(_ values: [(RelayV2Client, WorkRepository)]) {
        self.values = values
    }

    func next() throws -> (RelayV2Client, WorkRepository) {
        guard !values.isEmpty else {
            throw RelayV2ProtocolError.transport("No test HRP/2 setup remains")
        }
        return values.removeFirst()
    }
}

@MainActor
final class RelayV2ConnectionConfigurationTests: XCTestCase {
    private struct Setup {
        let keyStore: RelayV2KeychainStore
        let client: RelayV2Client
        let repository: WorkRepository
        let identity: RelayV2Identity
        let agentAgreement: RelayV2RawKeyPair
        let agentSigning: RelayV2RawKeyPair
    }

    private func makeSetup(accountID: String, suffix: String) throws -> Setup {
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.connection-setup.\(suffix).\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        var identity = RelayV2Identity.makeUnpaired(accountID: accountID)
        let keys = try XCTUnwrap(identity.currentKeys)
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device_\(suffix)"
        identity.agentRouteID = "rte_agent"
        let agentAgreement = RelayV2Crypto.generateAgreementKeyPair()
        let agentSigning = RelayV2Crypto.generateSigningKeyPair()
        identity.agentAgreementPublicKey = agentAgreement.publicKey
        identity.agentSigningPublicKey = agentSigning.publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        let repository = try WorkRepository(configuration: .init(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-v2-connection-setup-\(UUID().uuidString)")
        ))
        let client = try RelayV2Client(
            identity: identity,
            keyStore: keyStore,
            database: .inMemory(),
            hub: RelayV2HubTransport(
                configuration: try .init(
                    baseURL: URL(string: "https://relay.example.test")!,
                    routeID: try XCTUnwrap(identity.routeID),
                    routeSigningPrivateKey: keys.signingPrivateKey
                ),
                readinessProbeForTesting: {}
            ),
            workRepository: repository
        )
        return Setup(
            keyStore: keyStore,
            client: client,
            repository: repository,
            identity: identity,
            agentAgreement: agentAgreement,
            agentSigning: agentSigning
        )
    }

    func testPostAssignmentFailureTearsDownOnlyItsGenerationAndCannotClearNewerRetry() async throws {
        let defaults = UserDefaults.standard
        let priorTransport = defaults.object(forKey: DefaultsKeys.transportPath)
        let priorAccount = defaults.object(forKey: DefaultsKeys.relayV2AccountID)
        defer {
            if let priorTransport {
                defaults.set(priorTransport, forKey: DefaultsKeys.transportPath)
            } else {
                defaults.removeObject(forKey: DefaultsKeys.transportPath)
            }
            if let priorAccount {
                defaults.set(priorAccount, forKey: DefaultsKeys.relayV2AccountID)
            } else {
                defaults.removeObject(forKey: DefaultsKeys.relayV2AccountID)
            }
        }
        defaults.set(TransportPath.relayV2.rawValue, forKey: DefaultsKeys.transportPath)
        defaults.set("acc_configure_cleanup", forKey: DefaultsKeys.relayV2AccountID)

        let first = try makeSetup(accountID: "acc_configure_cleanup", suffix: "first")
        let second = try makeSetup(accountID: "acc_configure_cleanup", suffix: "second")
        defer {
            first.keyStore.deleteIdentity(accountID: "acc_configure_cleanup")
            second.keyStore.deleteIdentity(accountID: "acc_configure_cleanup")
        }
        let sequence = RelayV2SetupSequence([
            (first.client, first.repository),
            (second.client, second.repository),
        ])
        let gate = RelayV2ConfigureAssignmentGate()
        let sessions = SessionStore()
        let store = ConnectionStore(sessionStore: sessions, chatStore: ChatStore())
        store.relayV2SetupFactoryForTesting = { _ in try sequence.next() }
        store.relayV2PostAssignmentHookForTesting = {
            try await gate.pauseThenFail()
        }

        let staleAttempt = Task { @MainActor in
            await store.configure(urlString: "unused", token: "unused")
        }
        await gate.waitUntilCall(1)
        let freshAttempt = Task { @MainActor in
            await store.configure(urlString: "unused", token: "unused")
        }
        await gate.waitUntilCall(2)

        await gate.release(1)
        let staleResult = await staleAttempt.value
        XCTAssertNil(staleResult)
        let whileFreshIsInstalled = store.relayV2InstallationSnapshotForTesting()
        XCTAssertEqual(
            whileFreshIsInstalled.ownerGeneration,
            whileFreshIsInstalled.currentGeneration
        )
        XCTAssertTrue(whileFreshIsInstalled.hasClient)
        XCTAssertTrue(whileFreshIsInstalled.hasRepository)
        XCTAssertTrue(whileFreshIsInstalled.hasSessionsFetch)
        XCTAssertTrue(whileFreshIsInstalled.hasTranscriptFetch)
        let staleLifecycle = await first.client.connectionLifecycleSnapshotForTesting()
        XCTAssertFalse(staleLifecycle.connectionAttemptActive)
        XCTAssertFalse(staleLifecycle.commandDrainAcceptingWakeups)

        await gate.release(2)
        let freshResult = await freshAttempt.value
        XCTAssertNotNil(freshResult)
        let afterFreshFailure = store.relayV2InstallationSnapshotForTesting()
        XCTAssertNil(afterFreshFailure.ownerGeneration)
        XCTAssertFalse(afterFreshFailure.hasClient)
        XCTAssertFalse(afterFreshFailure.hasRepository)
        XCTAssertFalse(afterFreshFailure.hasSessionsFetch)
        XCTAssertFalse(afterFreshFailure.hasTranscriptFetch)
        let freshLifecycle = await second.client.connectionLifecycleSnapshotForTesting()
        XCTAssertFalse(freshLifecycle.connectionAttemptActive)
        XCTAssertFalse(freshLifecycle.commandDrainAcceptingWakeups)
    }

    func testTerminalRevocationImmediatelyClearsConnectionAdmission() async throws {
        let defaults = UserDefaults.standard
        let priorTransport = defaults.object(forKey: DefaultsKeys.transportPath)
        let priorAccount = defaults.object(forKey: DefaultsKeys.relayV2AccountID)
        defer {
            if let priorTransport {
                defaults.set(priorTransport, forKey: DefaultsKeys.transportPath)
            } else {
                defaults.removeObject(forKey: DefaultsKeys.transportPath)
            }
            if let priorAccount {
                defaults.set(priorAccount, forKey: DefaultsKeys.relayV2AccountID)
            } else {
                defaults.removeObject(forKey: DefaultsKeys.relayV2AccountID)
            }
        }
        let accountID = "acc_store_revoke"
        defaults.set(TransportPath.relayV2.rawValue, forKey: DefaultsKeys.transportPath)
        defaults.set(accountID, forKey: DefaultsKeys.relayV2AccountID)
        let setup = try makeSetup(accountID: accountID, suffix: "revoke")
        defer { setup.keyStore.deleteIdentity(accountID: accountID) }
        let sessions = SessionStore()
        let store = ConnectionStore(sessionStore: sessions, chatStore: ChatStore())
        store.relayV2SetupFactoryForTesting = { _ in
            (setup.client, setup.repository)
        }

        _ = await store.configure(urlString: "unused", token: "unused")
        XCTAssertTrue(store.relayV2Ready)
        XCTAssertEqual(store.phase, .connected)

        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let message = try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(),
            kind: .deviceRevoke,
            senderKeyGeneration: 1,
            createdAtMilliseconds: now,
            expiresAtMilliseconds: now + 60_000,
            body: ["device_id": .string(setup.identity.deviceID)]
        )
        let envelope = try RelayV2Crypto.sealAuthenticatedEnvelope(
            header: RelayV2OuterHeader(
                source: "rte_agent",
                destination: try XCTUnwrap(setup.identity.routeID),
                messageID: message.messageID,
                messageClass: .control,
                expiresAtMilliseconds: message.expiresAtMilliseconds,
                recipientKeyGeneration: 1
            ),
            message: message,
            recipientPublicKey: try XCTUnwrap(setup.identity.currentKeys).agreementPublicKey,
            senderAgreementPrivateKey: setup.agentAgreement.privateKey,
            senderSigningPrivateKey: setup.agentSigning.privateKey,
            purpose: .control,
            direction: .agentToDevice
        )
        do {
            try await setup.client.ingest(envelope)
            XCTFail("Expected authenticated revoke to terminate the client")
        } catch {
            XCTAssertEqual(error as? RelayV2ProtocolError, .revoked)
        }

        XCTAssertFalse(store.relayV2Ready)
        XCTAssertFalse(store.isTransportReady)
        XCTAssertEqual(store.phase, .needsSetup)
        let snapshot = store.relayV2InstallationSnapshotForTesting()
        XCTAssertFalse(snapshot.hasClient)
        XCTAssertFalse(snapshot.hasRepository)
        do {
            _ = try await store.enqueueRelayV2Prompt(text: "must reject", sessionID: nil)
            XCTFail("Revoked ConnectionStore accepted new relay work")
        } catch {
            // Expected: repository admission was removed with readiness.
        }
        let commands = try await setup.repository.relayV2Commands(accountID: accountID)
        XCTAssertTrue(commands.isEmpty)
    }
}

@MainActor
final class RelayV2PresenceLifecycleTests: XCTestCase {
    func testBackgroundClearWaitsForInflightHeartbeatAndIsNeverGated() async throws {
        let store = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())
        let capture = RelayV2PresenceCapture()
        store.relayV2PresenceEnqueueForTesting = { foreground, _ in
            await capture.append(foreground)
            if foreground {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        store.replaceRelayV2PresenceLifecycleForTesting(foreground: true)
        try await Task.sleep(for: .milliseconds(10))
        store.replaceRelayV2PresenceLifecycleForTesting(foreground: false)
        await store.waitForRelayV2PresenceLifecycleForTesting()
        let afterFirstClear = await capture.snapshot()
        XCTAssertEqual(afterFirstClear, [true, false])

        // A clear is still emitted after the preceding lifecycle has already
        // finished; it is not conditional on a running heartbeat task.
        store.replaceRelayV2PresenceLifecycleForTesting(foreground: false)
        await store.waitForRelayV2PresenceLifecycleForTesting()
        let afterSecondClear = await capture.snapshot()
        XCTAssertEqual(afterSecondClear, [true, false, false])
    }
}

@MainActor
private final class RelayV2SessionCapture {
    var projectedSessionID: String?
    var projectedItemIDs: [String] = []
    var boundOriginID: String?
    var boundLiveID: String?
}

@MainActor
final class RelayV2SessionBridgeTests: XCTestCase {
    func testCommittedTextDeltasPatchOnlyTheirStablePartsAndRequestFallbackWhenMissing() {
        let chat = ChatStore()
        chat.applyRelayItems([
            ChatItem(
                itemID: "prompt-1", type: .userMessage, status: .completed,
                ord: 0, body: ["text": "question"]
            ),
            ChatItem(
                itemID: "reasoning", type: .reasoning, status: .inProgress,
                ord: 1, body: ["text": "think"]
            ),
            ChatItem(
                itemID: "answer", type: .agentMessage, status: .inProgress,
                ord: 2, body: ["text": "hel"]
            ),
            ChatItem(
                itemID: "prompt-2", type: .userMessage, status: .completed,
                ord: 3, body: ["text": "next"]
            ),
            ChatItem(
                itemID: "tail", type: .agentMessage, status: .completed,
                ord: 4, body: ["text": "untouched"]
            ),
        ])
        let originalMessages = chat.messages
        let invalidationsBeforeDelta = chat.relayV2PartLocationIndexInvalidationCount

        XCTAssertTrue(chat.applyRelayV2TextDeltas(
            sessionID: "session",
            deltas: [
                .init(
                    sessionID: "session", itemID: "reasoning",
                    fromRevision: 1, toRevision: 3, data: " harder"
                ),
                .init(
                    sessionID: "session", itemID: "answer",
                    fromRevision: 4, toRevision: 7, data: "lo"
                ),
            ]
        ))
        XCTAssertEqual(chat.relayV2PartLocationIndexBuildCount, 1)
        XCTAssertEqual(chat.relayV2PartLocationIndexInvalidationCount, invalidationsBeforeDelta)
        XCTAssertEqual(chat.relayV2TargetedPartMutationCount, 2)
        XCTAssertEqual(chat.messages.map(\.id), originalMessages.map(\.id))
        XCTAssertEqual(chat.messages[1].thinking, "think harder")
        XCTAssertEqual(chat.messages[1].text, "hello")
        XCTAssertEqual(chat.messages[0], originalMessages[0])
        XCTAssertEqual(chat.messages[2], originalMessages[2])
        XCTAssertEqual(chat.messages[3], originalMessages[3])

        let repeatedDeltaCount = 2_048
        for index in 0..<repeatedDeltaCount {
            XCTAssertTrue(chat.applyRelayV2TextDeltas(
                sessionID: "session",
                deltas: [
                    .init(
                        sessionID: "session", itemID: "answer",
                        fromRevision: Int64(7 + index),
                        toRevision: Int64(8 + index),
                        data: "x"
                    ),
                ]
            ))
        }
        XCTAssertEqual(chat.relayV2PartLocationIndexBuildCount, 1,
                       "separate committed deltas must reuse the stable location index")
        XCTAssertEqual(chat.relayV2PartLocationIndexInvalidationCount, invalidationsBeforeDelta,
                       "target mutation must not publish a whole-list replacement")
        XCTAssertEqual(chat.relayV2TargetedPartMutationCount, repeatedDeltaCount + 2)
        XCTAssertEqual(
            chat.messages[1].text,
            "hello" + String(repeating: "x", count: repeatedDeltaCount)
        )
        XCTAssertEqual(chat.messages[0], originalMessages[0])
        XCTAssertEqual(chat.messages[2], originalMessages[2])
        XCTAssertEqual(chat.messages[3], originalMessages[3])

        chat.messages.append(ChatMessage(role: .system, text: "structural change"))
        let invalidationsAfterStructuralChange = chat.relayV2PartLocationIndexInvalidationCount
        XCTAssertGreaterThan(invalidationsAfterStructuralChange, invalidationsBeforeDelta)
        XCTAssertTrue(chat.applyRelayV2TextDeltas(
            sessionID: "session",
            deltas: [
                .init(
                    sessionID: "session", itemID: "answer",
                    fromRevision: Int64(7 + repeatedDeltaCount),
                    toRevision: Int64(8 + repeatedDeltaCount), data: "?"
                ),
            ]
        ))
        XCTAssertEqual(chat.relayV2PartLocationIndexBuildCount, 2,
                       "a structural transcript edit must rebuild before mutation")
        XCTAssertEqual(
            chat.relayV2PartLocationIndexInvalidationCount,
            invalidationsAfterStructuralChange
        )
        XCTAssertEqual(chat.relayV2TargetedPartMutationCount, repeatedDeltaCount + 3)
        XCTAssertEqual(
            chat.messages[1].text,
            "hello" + String(repeating: "x", count: repeatedDeltaCount) + "?"
        )

        let beforeMissingFallback = chat.messages
        XCTAssertFalse(chat.applyRelayV2TextDeltas(
            sessionID: "session",
            deltas: [
                .init(
                    sessionID: "session", itemID: "missing",
                    fromRevision: 1, toRevision: 2, data: "!"
                ),
            ]
        ))
        XCTAssertEqual(chat.messages, beforeMissingFallback,
                       "fallback discovery must not partially mutate any row")
        XCTAssertEqual(chat.relayV2PartLocationIndexBuildCount, 2)
        XCTAssertEqual(chat.relayV2TargetedPartMutationCount, repeatedDeltaCount + 3)
    }

    func testDistinctLiveSessionProjectsIntoDurableOriginAfterResume() async throws {
        let service = "ai.hermes.tests.session-alias.\(UUID().uuidString)"
        let keyStore = RelayV2KeychainStore(service: service, previewAccessGroup: nil)
        var identity = RelayV2Identity.makeUnpaired(accountID: "acc_session_bridge")
        let agent = RelayV2Crypto.generateAgreementKeyPair()
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = agent.publicKey
        identity.agentSigningPublicKey = RelayV2Crypto.generateSigningKeyPair().publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        let databaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-v2-session-db-\(UUID().uuidString)")
        let databaseConfiguration = RelayV2DatabaseConfiguration(
            containerURL: databaseDirectory
        )
        let database = try RelayV2Database(configuration: databaseConfiguration)
        let repository = try WorkRepository(configuration: .init(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-v2-session-work-\(UUID().uuidString)")
        ))
        let command = try await repository.enqueueRelayV2Command(
            operationID: "op_resume", clientMessageID: "msg_resume",
            accountID: identity.accountID, sessionID: "origin_session",
            kind: .sessionResume,
            payload: ["session_id": "origin_session"]
        )
        try await repository.markRelayV2Command(
            operationID: command.operationID, state: .accepted
        )
        let capture = RelayV2SessionCapture()
        let client = try RelayV2Client(
            identity: identity,
            keyStore: keyStore,
            database: database,
            hub: RelayV2HubTransport(configuration: try .init(
                baseURL: URL(string: "https://relay.example.test")!,
                routeID: "rte_device",
                routeSigningPrivateKey: try XCTUnwrap(identity.currentKeys).signingPrivateKey
            )),
            workRepository: repository,
            onProjection: { sessionID, items, _ in
                capture.projectedSessionID = sessionID
                capture.projectedItemIDs = items.map(\.itemID)
            },
            onSessionBinding: { originID, liveID in
                capture.boundOriginID = originID
                capture.boundLiveID = liveID
            }
        )
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        try await client.applyReceipt(RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(),
            kind: .rpcResponse,
            senderKeyGeneration: 1,
            createdAtMilliseconds: now,
            expiresAtMilliseconds: now + 60_000,
            body: [
                "jsonrpc": "2.0",
                "id": "msg_resume",
                "result": [
                    "origin_session_id": "origin_session",
                    "live_session_id": "live_session",
                ],
            ]
        ))
        XCTAssertEqual(capture.boundOriginID, "origin_session")
        XCTAssertEqual(capture.boundLiveID, "live_session")
        let storedOrigin = try await database.originSessionID(
            accountID: identity.accountID, liveSessionID: "live_session"
        )
        XCTAssertEqual(storedOrigin, "origin_session")

        let historyFrame = RelayV2WireFrame(
            sessionID: "origin_session", turnID: "old-turn", kind: "item.completed",
            body: [
                "item_id": "history_item", "session_id": "origin_session",
                "turn_id": "old-turn", "type": "agentMessage", "status": "completed",
                "ord": 0, "rev": 1, "summary": "", "body": ["text": "history"],
            ]
        )
        try await database.apply(
            accountID: identity.accountID, messageID: "history-batch",
            batch: .init(streamID: "history-stream", firstSequence: 1, frames: [historyFrame]),
            receivedAtMilliseconds: 1
        )
        let frame = RelayV2WireFrame(
            sessionID: "live_session", turnID: "turn", kind: "item.completed",
            body: [
                "item_id": "assistant_item", "session_id": "live_session",
                "turn_id": "turn", "type": "agentMessage", "status": "completed",
                "ord": 0, "rev": 1, "summary": "", "body": ["text": "hello"],
            ]
        )
        let batch = RelayV2FrameBatch(streamID: "stream", firstSequence: 1, frames: [frame])
        try await database.apply(
            accountID: identity.accountID, messageID: "batch", batch: batch,
            receivedAtMilliseconds: 2
        )
        try await client.publishProjection(for: batch, throughSequence: 1)
        XCTAssertEqual(capture.projectedSessionID, "origin_session")
        XCTAssertEqual(capture.projectedItemIDs, ["history_item", "assistant_item"])

        let checkpointItem: JSONValue = [
            "item_id": "checkpoint_item", "session_id": "live_session",
            "turn_id": "new-turn", "type": "agentMessage", "status": "completed",
            "ord": 0, "rev": 1, "summary": "", "body": ["text": "checkpoint"],
        ]
        try await database.applyCheckpoint(
            accountID: identity.accountID, messageID: "live-checkpoint",
            body: [
                "stream_id": "stream", "through_seq": 2, "session_id": "live_session",
                "snapshot_revision": 1, "replace": true,
                "items": .array([checkpointItem]), "tombstones": .array([]),
            ],
            receivedAtMilliseconds: 3
        )
        let reopened = try RelayV2Database(configuration: databaseConfiguration)
        let restartedProjection = try await reopened.projectionItems(
            accountID: identity.accountID, incomingSessionID: "live_session"
        )
        XCTAssertEqual(restartedProjection.originSessionID, "origin_session")
        XCTAssertEqual(
            restartedProjection.items.map(\.itemID),
            ["history_item", "checkpoint_item"]
        )
        keyStore.deleteIdentity(accountID: identity.accountID)
    }

    func testPromptRPCErrorRemovesOptimisticEchoAndSurfacesFailure() {
        let chat = ChatStore()
        chat.presentOutboxEcho(
            clientMessageID: "client_error", text: "hello", remotePaths: []
        )
        XCTAssertEqual(chat.messages.count, 1)
        chat.applyRelayV2CommandResolution(
            clientMessageID: "client_error",
            kind: .prompt,
            errorCode: .gatewayOffline
        )
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(chat.lastError, "The agent is offline. Try sending again.")

        chat.presentOutboxEcho(
            clientMessageID: "client_ambiguous", text: "uncertain", remotePaths: []
        )
        chat.applyRelayV2CommandResolution(
            clientMessageID: "client_ambiguous",
            kind: .prompt,
            errorCode: .gatewayAmbiguous
        )
        XCTAssertEqual(chat.messages.map(\.clientMessageID), ["client_ambiguous"])
        XCTAssertEqual(chat.lastError, "The relay could not confirm delivery.")
    }

    func testApprovalPayloadRetainsDeviceBoundCapability() {
        let capability = RelayV2Wire.base64URL(Data(repeating: 7, count: 32))
        let payload = ApprovalRequestPayload(payload: [
            "request_id": "request",
            "command": "rm file",
            "capability": .string(capability),
            "allowed_decisions": ["approve_once", "deny"],
            "device_id": "device",
            "device_generation": 3,
        ])
        XCTAssertEqual(payload.id, "request")
        XCTAssertEqual(payload.capability, capability)
        XCTAssertEqual(payload.allowedDecisions, ["approve_once", "deny"])
        XCTAssertEqual(payload.deviceID, "device")
        XCTAssertEqual(payload.deviceGeneration, 3)
        let approval = try? ChatStore.relayV2ApprovalParams(
            sessionID: "origin", request: payload, approve: true
        )
        XCTAssertEqual(
            Set(approval?.keys.map { $0 } ?? []),
            ["session_id", "request_id", "decision", "capability"]
        )
        XCTAssertEqual(approval?["decision"]?.stringValue, "approve_once")
    }

    func testRelayClarificationAndPresenceHaveExactWireShapes() throws {
        XCTAssertLessThan(ConnectionStore.relayV2PresenceHeartbeatSeconds, 90)
        let clarification = try ChatStore.relayV2ClarificationParams(
            sessionID: "origin", requestID: "request", text: "answer"
        )
        XCTAssertEqual(Set(clarification.keys), ["session_id", "request_id", "text"])
        XCTAssertNil(clarification["answer"])

        let foreground = try RelayV2RPCRequestFactory.make(
            kind: .presenceSet,
            operationID: "op_presence_foreground",
            clientMessageID: "msg_presence_foreground",
            params: ["foreground": true, "session_id": "origin"]
        )
        XCTAssertEqual(foreground["method"]?.stringValue, "presence.set")
        XCTAssertEqual(
            Set(foreground["params"]?.objectValue?.keys.map { $0 } ?? []),
            ["foreground", "session_id"]
        )
        let background = try RelayV2RPCRequestFactory.make(
            kind: .presenceSet,
            operationID: "op_presence_background",
            clientMessageID: "msg_presence_background",
            params: ["foreground": false]
        )
        XCTAssertEqual(
            Set(background["params"]?.objectValue?.keys.map { $0 } ?? []),
            ["foreground"]
        )
        XCTAssertEqual(background["params"]?["foreground"]?.boolValue, false)
    }
}

private actor RelayV2MigrationCleanupGate {
    private let outcomes: [PushTokenPoster.Outcome]
    private var intents: [RelayV2MigrationIntent] = []
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCallReleased = false
    private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(outcomes: [PushTokenPoster.Outcome]) {
        self.outcomes = outcomes
    }

    func unregister(_ intent: RelayV2MigrationIntent) async -> PushTokenPoster.Outcome {
        intents.append(intent)
        let call = intents.count
        if call == 1 {
            let waiters = firstCallWaiters
            firstCallWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !firstCallReleased {
                await withCheckedContinuation { firstReleaseWaiters.append($0) }
            }
        }
        return outcomes[min(call - 1, outcomes.count - 1)]
    }

    func waitUntilFirstCall() async {
        if !intents.isEmpty { return }
        await withCheckedContinuation { firstCallWaiters.append($0) }
    }

    func releaseFirstCall() {
        guard !firstCallReleased else { return }
        firstCallReleased = true
        let waiters = firstReleaseWaiters
        firstReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func capturedIntents() -> [RelayV2MigrationIntent] { intents }
}

private enum RelayV2PairConfirmRetryError: Error {
    case injectedFailure
}

private actor RelayV2PairConfirmRetryTransport: RelayV2PairingTransport {
    private var sendCount = 0

    func submitPairInit(
        offer: RelayV2PairingOffer,
        encapsulatedKey: Data,
        ciphertext: Data
    ) async throws {}

    func fetchPairAccept(
        offer: RelayV2PairingOffer
    ) async throws -> RelayV2PairAcceptMailbox? { nil }

    func sendPairConfirm(
        _ envelope: RelayV2OuterEnvelope,
        hubURL: URL,
        routeSigningPrivateKey: Data
    ) async throws {
        sendCount += 1
        if sendCount == 1 {
            throw RelayV2PairConfirmRetryError.injectedFailure
        }
    }

    func confirmationCount() -> Int { sendCount }
}

private actor RelayV2PairConfirmSuccessTransport: RelayV2PairingTransport {
    private var sendCount = 0

    func submitPairInit(
        offer: RelayV2PairingOffer,
        encapsulatedKey: Data,
        ciphertext: Data
    ) async throws {}

    func fetchPairAccept(
        offer: RelayV2PairingOffer
    ) async throws -> RelayV2PairAcceptMailbox? { nil }

    func sendPairConfirm(
        _ envelope: RelayV2OuterEnvelope,
        hubURL: URL,
        routeSigningPrivateKey: Data
    ) async throws {
        sendCount += 1
    }

    func confirmationCount() -> Int { sendCount }
}

private actor RelayV2PairingEnrollmentCapture: RelayV2PairingEnrollmentTransport {
    struct Request: Equatable, Sendable {
        let accountID: String
        let apnsToken: Data
        let environment: RelayV2APNsEnvironment
        let bundleID: String
        let previewPublicKey: Data
        let installationNonce: Data
        let hubRouteID: String?
    }

    private var requests: [Request] = []

    func register(
        accountID: String,
        apnsToken: Data,
        environment: RelayV2APNsEnvironment,
        bundleID: String,
        previewKEMPublicKey: Data,
        installationNonce: Data,
        hubRouteID: String?,
        existingAppAttestKeyID: String?
    ) async throws -> RelayV2PushRegistrationResult {
        requests.append(.init(
            accountID: accountID,
            apnsToken: apnsToken,
            environment: environment,
            bundleID: bundleID,
            previewPublicKey: previewKEMPublicKey,
            installationNonce: installationNonce,
            hubRouteID: hubRouteID
        ))
        let bind = RelayV2Wire.base64URL(Data(repeating: 4, count: 32))
        return try JSONDecoder().decode(
            RelayV2PushRegistrationResult.self,
            from: Data(
                """
                {"endpoint_id":"ep_pairing","bind_token":"\(bind)","bind_token_expires_at_ms":9999999999999,"hub_activation_token":"activate_pairing","hub_activation_token_expires_at_ms":9999999999999,"app_attest_key_id":"attest_pairing"}
                """.utf8
            )
        )
    }

    func activateHub(
        accountID: String,
        environment: RelayV2APNsEnvironment,
        bundleID: String,
        installationNonce: Data,
        hubRouteID: String
    ) async throws -> RelayV2HubActivationResult {
        throw RelayV2ProtocolError.transport("Unexpected hub-only enrollment")
    }

    func capturedRequests() -> [Request] { requests }
}

@MainActor
final class RelayV2MigrationTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "ai.hermes.tests.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testLegacyAPNsPlaintextMigratesToSeparateThisDeviceKeychainRecords() throws {
        let (defaults, suite) = makeDefaults()
        KeychainService.deleteAPNsDeviceTokens(defaults: defaults)
        defer {
            KeychainService.deleteAPNsDeviceTokens(defaults: defaults)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set("current-token", forKey: DefaultsKeys.pushAPNsDeviceToken)
        defaults.set("registered-token", forKey: DefaultsKeys.pushLastDeviceToken)

        XCTAssertEqual(
            KeychainService.loadAPNsDeviceToken(defaults: defaults),
            "current-token"
        )
        XCTAssertEqual(
            KeychainService.loadRegisteredAPNsDeviceToken(defaults: defaults),
            "registered-token"
        )
        XCTAssertNil(defaults.string(forKey: DefaultsKeys.pushAPNsDeviceToken))
        XCTAssertNil(defaults.string(forKey: DefaultsKeys.pushLastDeviceToken))
    }

    func testCutoverFencesImmediatelyAndRestartRetriesExactLegacyDeleteIntent() async throws {
        let (defaults, suite) = makeDefaults()
        KeychainService.deleteAPNsDeviceTokens(defaults: defaults)
        defer {
            KeychainService.deleteAPNsDeviceTokens(defaults: defaults)
            defaults.removePersistentDomain(forName: suite)
        }
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.migration.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        defer {
            keyStore.deleteMigrationIntent()
            keyStore.deleteEnrollmentState(accountID: "acc_migration")
        }
        defaults.set("legacy-apns-token", forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.set(["approval", "clarify"], forKey: DefaultsKeys.pushLastEvents)
        defaults.set("sandbox", forKey: DefaultsKeys.pushLastEnv)
        defaults.set("legacy-scope", forKey: DefaultsKeys.pushLastRegistrationScope)
        defaults.set("raw-current-apns", forKey: DefaultsKeys.pushAPNsDeviceToken)
        try keyStore.savePushRegistrationState(.init(
            accountID: "acc_migration",
            endpointID: "v2-endpoint",
            appAttestKeyID: "v2-attest",
            pendingAttestation: nil,
            pendingRequestBody: nil,
            pendingRequestExpiresAtMilliseconds: nil,
            attestationPhase: .committed,
            installationNonce: Data(repeating: 1, count: 32),
            previewPublicKey: Data(repeating: 2, count: 32),
            environment: .sandbox
        ))
        let legacyURL = try XCTUnwrap(URL(string: "https://old-gateway.example.test/root"))
        let gate = RelayV2MigrationCleanupGate(outcomes: [.hardFail, .success])
        let coordinator = RelayV2MigrationCoordinator(
            defaults: defaults,
            keyStore: keyStore,
            legacyEndpointProvider: {
                (legacyURL, "legacy-secret-token", .plugin)
            },
            unregisterLegacyPush: { intent in
                await gate.unregister(intent)
            }
        )

        let activation = Task { @MainActor in
            try await coordinator.activate(accountID: "acc_migration")
        }
        await gate.waitUntilFirstCall()

        XCTAssertFalse(DefaultsKeys.legacyDirectActionsAllowed(defaults))
        XCTAssertEqual(DefaultsKeys.transportPathValue(defaults), .relayV2)
        XCTAssertEqual(
            DefaultsKeys.relayV2AccountIDValue(defaults),
            "acc_migration"
        )
        XCTAssertTrue(defaults.bool(forKey: DefaultsKeys.pushRegistrationHealthy))
        let journaled = try XCTUnwrap(keyStore.loadMigrationIntent())
        XCTAssertEqual(journaled.accountID, "acc_migration")
        XCTAssertEqual(journaled.legacyBaseURL, legacyURL)
        XCTAssertEqual(journaled.legacySessionToken, "legacy-secret-token")
        XCTAssertEqual(journaled.legacyAPNsToken, "legacy-apns-token")
        XCTAssertEqual(journaled.legacyPathStyle, APIPathStyle.plugin.rawValue)
        XCTAssertNil(defaults.string(forKey: DefaultsKeys.pushLastDeviceToken))
        XCTAssertNil(defaults.string(forKey: DefaultsKeys.pushAPNsDeviceToken))
        XCTAssertEqual(
            KeychainService.loadRegisteredAPNsDeviceToken(defaults: defaults),
            "legacy-apns-token"
        )
        XCTAssertEqual(
            KeychainService.loadAPNsDeviceToken(defaults: defaults),
            "raw-current-apns"
        )

        await gate.releaseFirstCall()
        try await activation.value
        XCTAssertEqual(try keyStore.loadMigrationIntent(), journaled)

        // A reconstructed coordinator must use the protected tuple, not resolve
        // whatever gateway happens to be current after the transport switch.
        let restarted = RelayV2MigrationCoordinator(
            defaults: defaults,
            keyStore: keyStore,
            legacyEndpointProvider: { nil },
            unregisterLegacyPush: { intent in
                await gate.unregister(intent)
            }
        )
        await restarted.resumePendingCutover()
        let captured = await gate.capturedIntents()
        XCTAssertEqual(captured, [journaled, journaled])
        XCTAssertNil(try keyStore.loadMigrationIntent())
        XCTAssertNil(defaults.string(forKey: DefaultsKeys.pushLastDeviceToken))
        XCTAssertNil(defaults.object(forKey: DefaultsKeys.pushLastEvents))
        XCTAssertNil(defaults.string(forKey: DefaultsKeys.pushLastEnv))
        XCTAssertNil(defaults.string(forKey: DefaultsKeys.pushLastRegistrationScope))
        XCTAssertNil(KeychainService.loadRegisteredAPNsDeviceToken(defaults: defaults))
        XCTAssertEqual(
            KeychainService.loadAPNsDeviceToken(defaults: defaults),
            "raw-current-apns"
        )
        XCTAssertNotNil(
            try keyStore.loadPushRegistrationState(accountID: "acc_migration")
        )
        XCTAssertTrue(defaults.bool(forKey: DefaultsKeys.pushRegistrationHealthy))
    }
}

@MainActor
final class RelayV2PairingRestartTests: XCTestCase {
    private actor Transport: RelayV2PairingTransport {
        func submitPairInit(
            offer: RelayV2PairingOffer, encapsulatedKey: Data, ciphertext: Data
        ) async throws {}
        func fetchPairAccept(offer: RelayV2PairingOffer) async throws -> RelayV2PairAcceptMailbox? { nil }
        func sendPairConfirm(
            _ envelope: RelayV2OuterEnvelope,
            hubURL: URL,
            routeSigningPrivateKey: Data
        ) async throws {}
    }

    func testPendingPairingRestoresAfterProcessBoundary() throws {
        let service = "ai.hermes.tests.pairing.\(UUID().uuidString)"
        let keyStore = RelayV2KeychainStore(service: service, previewAccessGroup: nil)
        let key = Data(repeating: 8, count: 32)
        let payload = """
        {"v":2,"hub":"https://relay.example.test","relay_route":"rte_agent","offer_route":"off_route","offer_id":"ofr_restart","offer_transport_token":"\(RelayV2Wire.base64URL(key))","expires_at_ms":9999999999999,"relay_kem_pub":"\(RelayV2Wire.base64URL(key))","relay_sign_pub":"\(RelayV2Wire.base64URL(key))","pair_secret":"\(RelayV2Wire.base64URL(key))"}
        """
        let offer = try RelayV2PairingOffer.decodeScannerPayload(payload)
        let identity = RelayV2Identity.makeUnpaired(accountID: "acc_restart")
        let current = try XCTUnwrap(identity.currentKeys)
        let preview = RelayV2Crypto.generateAgreementKeyPair()
        let pairInit = RelayV2PairInit(
            offerID: offer.offerID, deviceName: "Test Phone",
            deviceAgreementPublicKey: try current.agreementPublicKey,
            deviceSigningPublicKey: try current.signingPublicKey,
            previewPublicKey: preview.publicKey, deviceNonce: Data(repeating: 1, count: 16),
            pushBindToken: "legacy-bind", hubActivationToken: "legacy-activation",
            pairMAC: Data(repeating: 2, count: 32)
        )
        try keyStore.savePendingPairing(.init(
            offer: offer, identity: identity, preview: preview, pairInit: pairInit,
            pairInitEncapsulatedKey: Data(repeating: 3, count: 32),
            pairInitCiphertext: Data(repeating: 4, count: 32),
            messageHash: Data(repeating: 5, count: 32), pairInitSubmitted: true,
            pairAcceptMailbox: nil, pairAcceptMessageID: nil, confirmEnvelope: nil
        ))

        let restored = RelayV2PairingCoordinator(transport: Transport(), keyStore: keyStore)
        guard case .awaitingAccept(let code) = restored.state else {
            return XCTFail("Expected a restored waiting transaction")
        }
        XCTAssertEqual(code.count, 7)
        let sanitized = try XCTUnwrap(keyStore.loadPendingPairing())
        XCTAssertNil(sanitized.pairInit.pushBindToken)
        XCTAssertNil(sanitized.pairInit.hubActivationToken)
        XCTAssertEqual(sanitized.verificationCode, code)
        XCTAssertEqual(sanitized.pairInitCiphertext, Data(repeating: 4, count: 32))
        restored.cancel()
        XCTAssertNil(try keyStore.loadPendingPairing())
    }

    func testHostedEnrollmentPreflightRescanReusesExactKeysNonceAndRequest() async throws {
        let service = "ai.hermes.tests.pairing-preflight.\(UUID().uuidString)"
        let keyStore = RelayV2KeychainStore(service: service, previewAccessGroup: nil)
        let key = Data(repeating: 8, count: 32)
        let payload = """
        {"v":2,"hub":"https://relay.example.test","relay_route":"rte_agent","offer_route":"off_preflight","offer_id":"ofr_preflight","offer_transport_token":"\(RelayV2Wire.base64URL(key))","expires_at_ms":9999999999999,"relay_kem_pub":"\(RelayV2Wire.base64URL(key))","relay_sign_pub":"\(RelayV2Wire.base64URL(key))","pair_secret":"\(RelayV2Wire.base64URL(key))"}
        """
        let offer = try RelayV2PairingOffer.decodeScannerPayload(payload)
        let originalPreview = RelayV2Crypto.generateAgreementKeyPair()
        let originalNonce = Data(repeating: 0x11, count: 32)
        let originalAPNs = Data(repeating: 0x22, count: 32)
        let first = RelayV2PairingCoordinator(transport: Transport(), keyStore: keyStore)
        let prepared = try first.prepareHostedEnrollment(
            offer: offer,
            deviceName: "Original Phone",
            notificationsEnabled: true,
            apnsToken: originalAPNs,
            environment: .sandbox,
            bundleID: "ai.hermes.app",
            previewKeyPair: originalPreview,
            installationNonce: originalNonce
        )
        XCTAssertEqual(try keyStore.loadPendingPairingEnrollment(), prepared)

        // A new view/coordinator after termination may supply fresh UI defaults
        // and newly generated crypto. The saved transaction must win verbatim.
        let restarted = RelayV2PairingCoordinator(transport: Transport(), keyStore: keyStore)
        let rescanned = try restarted.prepareHostedEnrollment(
            offer: offer,
            deviceName: "Changed Phone",
            notificationsEnabled: false,
            apnsToken: nil,
            environment: .production,
            bundleID: "changed.bundle",
            previewKeyPair: RelayV2Crypto.generateAgreementKeyPair(),
            installationNonce: Data(repeating: 0x99, count: 32)
        )
        XCTAssertEqual(rescanned, prepared)

        let enrollment = RelayV2PairingEnrollmentCapture()
        _ = try await restarted.enrollHostedAndBegin(
            offer: offer,
            deviceName: "Changed Again",
            notificationsEnabled: false,
            apnsToken: nil,
            environment: .production,
            bundleID: "another.bundle",
            enrollmentTransport: enrollment
        )
        let capturedRequests = await enrollment.capturedRequests()
        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(request.accountID, "pairing_\(offer.offerID)")
        XCTAssertEqual(request.apnsToken, originalAPNs)
        XCTAssertEqual(request.environment, .sandbox)
        XCTAssertEqual(request.bundleID, "ai.hermes.app")
        XCTAssertEqual(request.previewPublicKey, originalPreview.publicKey)
        XCTAssertEqual(request.installationNonce, originalNonce)
        XCTAssertEqual(request.hubRouteID, offer.relayRoute)
        let pending = try XCTUnwrap(keyStore.loadPendingPairing())
        XCTAssertEqual(pending.preview, originalPreview)
        XCTAssertEqual(pending.pairInit.deviceName, "Original Phone")
        XCTAssertEqual(pending.pairInit.previewPublicKey, originalPreview.publicKey)
        XCTAssertNil(pending.pairInit.pushBindToken)
        XCTAssertNil(pending.pairInit.hubActivationToken)
        XCTAssertEqual(pending.verificationCode?.count, 7)
        XCTAssertNil(try keyStore.loadPendingPairingEnrollment())
        restarted.cancel()
    }

    func testFailedPairConfirmKeepsLegacyTransportAndRestartActivatesV2() async throws {
        let suite = "ai.hermes.tests.pairing-retry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        KeychainService.deleteAPNsDeviceTokens(defaults: defaults)
        defer {
            KeychainService.deleteAPNsDeviceTokens(defaults: defaults)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(
            TransportPath.gatewayDirect.rawValue,
            forKey: DefaultsKeys.transportPath
        )
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.pairing-retry.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        let accountID = "acc_pair_retry"
        defer {
            keyStore.deleteIdentity(accountID: accountID)
            keyStore.deleteEnrollmentState(accountID: accountID)
            keyStore.deleteMigrationIntent()
            keyStore.deletePendingPairing()
        }
        let pending = try makePendingConfirmation(accountID: accountID)
        try keyStore.savePendingPairing(pending)
        let transport = RelayV2PairConfirmRetryTransport()
        let migration = RelayV2MigrationCoordinator(
            defaults: defaults,
            keyStore: keyStore,
            legacyEndpointProvider: { nil },
            unregisterLegacyPush: { _ in .success }
        )
        let first = RelayV2PairingCoordinator(
            transport: transport,
            keyStore: keyStore,
            defaults: defaults,
            migrationCoordinator: migration
        )
        guard case .confirming = first.state else {
            return XCTFail("Expected restored PairConfirm state")
        }
        do {
            _ = try await first.pollAndConfirm()
            XCTFail("Expected the first PairConfirm send to fail")
        } catch {}
        XCTAssertEqual(DefaultsKeys.transportPathValue(defaults), .gatewayDirect)
        XCTAssertTrue(DefaultsKeys.legacyDirectActionsAllowed(defaults))
        XCTAssertNotNil(try keyStore.loadPendingPairing())

        let restarted = RelayV2PairingCoordinator(
            transport: transport,
            keyStore: keyStore,
            defaults: defaults,
            migrationCoordinator: migration
        )
        let identity = try await restarted.pollAndConfirm()
        XCTAssertEqual(identity?.accountID, accountID)
        XCTAssertEqual(restarted.state, .paired(accountID))
        XCTAssertEqual(DefaultsKeys.transportPathValue(defaults), .relayV2)
        XCTAssertFalse(DefaultsKeys.legacyDirectActionsAllowed(defaults))
        XCTAssertEqual(DefaultsKeys.relayV2AccountIDValue(defaults), accountID)
        XCTAssertNil(try keyStore.loadPendingPairing())
        XCTAssertNotNil(try keyStore.loadIdentity(accountID: accountID))
        XCTAssertNotNil(try keyStore.loadPreviewKey(accountID: accountID))
        let confirmationCount = await transport.confirmationCount()
        XCTAssertEqual(confirmationCount, 2)
    }

    func testAcceptedPairConfirmSurvivesMigrationFailureCancelAndResume() async throws {
        let suite = "ai.hermes.tests.pairing-accepted.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        KeychainService.deleteAPNsDeviceTokens(defaults: defaults)
        defer {
            KeychainService.deleteAPNsDeviceTokens(defaults: defaults)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(
            TransportPath.gatewayDirect.rawValue,
            forKey: DefaultsKeys.transportPath
        )
        defaults.set("legacy-apns-token", forKey: DefaultsKeys.pushLastDeviceToken)
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.pairing-accepted.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        let accountID = "acc_pair_accepted"
        defer {
            keyStore.deleteIdentity(accountID: accountID)
            keyStore.deleteEnrollmentState(accountID: accountID)
            keyStore.deleteMigrationIntent()
            keyStore.deletePendingPairing()
        }
        try keyStore.savePendingPairing(
            try makePendingConfirmation(accountID: accountID)
        )
        let transport = RelayV2PairConfirmSuccessTransport()
        let failingMigration = RelayV2MigrationCoordinator(
            defaults: defaults,
            keyStore: keyStore,
            legacyEndpointProvider: { nil },
            unregisterLegacyPush: { _ in .success }
        )
        let first = RelayV2PairingCoordinator(
            transport: transport,
            keyStore: keyStore,
            defaults: defaults,
            migrationCoordinator: failingMigration
        )

        do {
            _ = try await first.pollAndConfirm()
            XCTFail("Expected local migration to fail after Hub acceptance")
        } catch {
            // Expected: the exact legacy endpoint could not be journaled.
        }
        let firstConfirmationCount = await transport.confirmationCount()
        XCTAssertEqual(firstConfirmationCount, 1)
        XCTAssertNotNil(try keyStore.loadPendingPairing())
        XCTAssertEqual(DefaultsKeys.transportPathValue(defaults), .gatewayDirect)

        first.cancel()
        XCTAssertNotNil(
            try keyStore.loadPendingPairing(),
            "cancel must not destroy work the Hub already accepted"
        )

        KeychainService.deleteRegisteredAPNsDeviceToken(defaults: defaults)
        let resumed = RelayV2PairingCoordinator(
            transport: transport,
            keyStore: keyStore,
            defaults: defaults,
            migrationCoordinator: RelayV2MigrationCoordinator(
                defaults: defaults,
                keyStore: keyStore,
                legacyEndpointProvider: { nil },
                unregisterLegacyPush: { _ in .success }
            )
        )
        let identity = try await resumed.pollAndConfirm()
        XCTAssertEqual(identity?.accountID, accountID)
        let finalConfirmationCount = await transport.confirmationCount()
        XCTAssertEqual(finalConfirmationCount, 1)
        XCTAssertEqual(DefaultsKeys.transportPathValue(defaults), .relayV2)
        XCTAssertNil(try keyStore.loadPendingPairing())
    }

    func testExpiredHubAcceptedPairingSurvivesRelaunchAndCancel() async throws {
        let suite = "ai.hermes.tests.pairing-accepted-expired.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.pairing-accepted-expired.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        let accountID = "acc_pair_accepted_expired"
        defer {
            keyStore.deleteIdentity(accountID: accountID)
            keyStore.deletePreviewKey(accountID: accountID)
            keyStore.deleteEnrollmentState(accountID: accountID)
            keyStore.deleteMigrationIntent()
            keyStore.deletePendingPairing()
        }
        var accepted = try makePendingConfirmation(
            accountID: accountID,
            offerExpiresAtMilliseconds: 1
        )
        accepted.pairConfirmAcceptedByHub = true
        try keyStore.savePendingPairing(accepted)
        let transport = RelayV2PairConfirmSuccessTransport()

        let relaunched = RelayV2PairingCoordinator(
            transport: transport,
            keyStore: keyStore,
            defaults: defaults,
            migrationCoordinator: RelayV2MigrationCoordinator(
                defaults: defaults,
                keyStore: keyStore,
                legacyEndpointProvider: { nil },
                unregisterLegacyPush: { _ in .success }
            )
        )
        XCTAssertEqual(relaunched.state, .confirming)
        relaunched.cancel()
        XCTAssertNotNil(try keyStore.loadPendingPairing())

        let identity = try await relaunched.pollAndConfirm()
        XCTAssertEqual(identity?.accountID, accountID)
        XCTAssertEqual(relaunched.state, .paired(accountID))
        XCTAssertEqual(DefaultsKeys.transportPathValue(defaults), .relayV2)
        XCTAssertNil(try keyStore.loadPendingPairing())
        let confirmationCount = await transport.confirmationCount()
        XCTAssertEqual(confirmationCount, 0)
    }

    private func makePendingConfirmation(
        accountID: String,
        offerExpiresAtMilliseconds: UInt64 = 9_999_999_999_999
    ) throws -> RelayV2PendingPairingRecord {
        let relayAgreement = RelayV2Crypto.generateAgreementKeyPair()
        let relaySigning = RelayV2Crypto.generateSigningKeyPair()
        let pairSecret = Data(repeating: 8, count: 32)
        let payload = """
        {"v":2,"hub":"https://relay.example.test","relay_route":"rte_agent","offer_route":"off_retry","offer_id":"ofr_retry","offer_transport_token":"\(RelayV2Wire.base64URL(pairSecret))","expires_at_ms":\(offerExpiresAtMilliseconds),"relay_kem_pub":"\(RelayV2Wire.base64URL(relayAgreement.publicKey))","relay_sign_pub":"\(RelayV2Wire.base64URL(relaySigning.publicKey))","pair_secret":"\(RelayV2Wire.base64URL(pairSecret))"}
        """
        let offer = try RelayV2PairingOffer.decodeScannerPayload(payload)
        var identity = RelayV2Identity.makeUnpaired(accountID: accountID)
        identity.hubURL = offer.hubURL
        identity.routeID = "rte_device"
        identity.agentRouteID = offer.relayRoute
        identity.streamID = "str_pair_retry"
        identity.relayInstanceID = "rly_pair_retry"
        identity.agentAgreementPublicKey = relayAgreement.publicKey
        identity.agentSigningPublicKey = relaySigning.publicKey
        identity.agentKeyGeneration = 1
        let keys = try XCTUnwrap(identity.currentKeys)
        let preview = RelayV2Crypto.generateAgreementKeyPair()
        let pairInit = RelayV2PairInit(
            offerID: offer.offerID,
            deviceName: "Test Phone",
            deviceAgreementPublicKey: try keys.agreementPublicKey,
            deviceSigningPublicKey: try keys.signingPublicKey,
            previewPublicKey: preview.publicKey,
            deviceNonce: Data(repeating: 1, count: 16),
            pushBindToken: nil,
            hubActivationToken: nil,
            pairMAC: Data(repeating: 2, count: 32)
        )
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let secureMessage = try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(),
            kind: .pairConfirm,
            senderKeyGeneration: keys.generation,
            createdAtMilliseconds: now,
            expiresAtMilliseconds: now + 60_000,
            body: [
                "offer_id": .string(offer.offerID),
                "device_id": .string(identity.deviceID),
                "response_hash": .string(
                    RelayV2Wire.base64URL(Data(repeating: 3, count: 32))
                ),
                "pair_accept_mid": .string(RelayV2Wire.randomMessageID()),
            ]
        )
        let envelope = try RelayV2Crypto.sealAuthenticatedEnvelope(
            header: RelayV2OuterHeader(
                source: "rte_device",
                destination: offer.relayRoute,
                messageID: secureMessage.messageID,
                messageClass: .control,
                expiresAtMilliseconds: secureMessage.expiresAtMilliseconds,
                recipientKeyGeneration: 1
            ),
            message: secureMessage,
            recipientPublicKey: relayAgreement.publicKey,
            senderAgreementPrivateKey: keys.agreementPrivateKey,
            senderSigningPrivateKey: keys.signingPrivateKey,
            purpose: .control,
            direction: .deviceToAgent
        )
        return RelayV2PendingPairingRecord(
            offer: offer,
            identity: identity,
            preview: preview,
            pairInit: pairInit,
            pairInitEncapsulatedKey: Data(repeating: 4, count: 32),
            pairInitCiphertext: Data(repeating: 5, count: 32),
            messageHash: Data(repeating: 6, count: 32),
            pairInitSubmitted: true,
            pairAcceptMailbox: nil,
            pairAcceptMessageID: secureMessage.body["pair_accept_mid"]?.stringValue,
            confirmEnvelope: envelope
        )
    }
}

final class RelayV2KeyRotationTests: XCTestCase {
    func testAuthenticatedKEMAndPreviewRotationRetainBoundedOverlap() async throws {
        let service = "ai.hermes.tests.rotate.\(UUID().uuidString)"
        let keyStore = RelayV2KeychainStore(service: service, previewAccessGroup: nil)
        var identity = RelayV2Identity.makeUnpaired(accountID: "acc_rotate")
        let originalAgent = RelayV2Crypto.generateAgreementKeyPair()
        let agentSigning = RelayV2Crypto.generateSigningKeyPair()
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = originalAgent.publicKey
        identity.agentSigningPublicKey = agentSigning.publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        try keyStore.savePreviewKey(.init(
            accountID: identity.accountID,
            privateKey: RelayV2Crypto.generateAgreementKeyPair().privateKey,
            agentAgreementPublicKey: originalAgent.publicKey,
            generation: 1
        ))
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-v2-rotate-work-\(UUID().uuidString)")
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: workDirectory)
        )
        let client = try RelayV2Client(
            identity: identity,
            keyStore: keyStore,
            database: RelayV2Database.inMemory(),
            hub: RelayV2HubTransport(configuration: try .init(
                baseURL: URL(string: "https://relay.example.test")!,
                routeID: "rte_device",
                routeSigningPrivateKey: try XCTUnwrap(identity.currentKeys).signingPrivateKey
            )),
            workRepository: repository
        )
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let deadline = now + 60_000
        let newKEM = RelayV2Crypto.generateAgreementKeyPair()
        let kemMessage = try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(), kind: .keyRotate,
            senderKeyGeneration: 1, createdAtMilliseconds: now,
            expiresAtMilliseconds: deadline,
            body: [
                "purpose": "kem", "generation": 2,
                "public_key": .string(RelayV2Wire.base64URL(newKEM.publicKey)),
                "previous_not_after_ms": .number(Double(deadline)),
            ]
        )
        try await client.applyKeyRotation(kemMessage, nowMilliseconds: now)
        try await client.applyKeyRotation(kemMessage, nowMilliseconds: now)
        let storedIdentity = try XCTUnwrap(keyStore.loadIdentity(accountID: identity.accountID))
        XCTAssertEqual(storedIdentity.agentKeyGeneration, 2)
        XCTAssertEqual(storedIdentity.activeAgentAgreementKeys(nowMilliseconds: now).map(\.generation), [1, 2])
        XCTAssertEqual(storedIdentity.activeAgentAgreementKeys(nowMilliseconds: deadline).map(\.generation), [2])

        let newPreviewSender = RelayV2Crypto.generateAgreementKeyPair()
        let previewMessage = try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(), kind: .keyRotate,
            senderKeyGeneration: 2, createdAtMilliseconds: now,
            expiresAtMilliseconds: deadline,
            body: [
                "purpose": "preview", "generation": 2,
                "public_key": .string(RelayV2Wire.base64URL(newPreviewSender.publicKey)),
                "previous_not_after_ms": .number(Double(deadline)),
            ]
        )
        try await client.applyKeyRotation(previewMessage, nowMilliseconds: now)
        try await client.applyKeyRotation(previewMessage, nowMilliseconds: now)
        let preview = try XCTUnwrap(keyStore.loadPreviewKey(accountID: identity.accountID))
        XCTAssertEqual(preview.generation, 1)
        XCTAssertEqual(preview.agentGeneration, 2)
        XCTAssertEqual(preview.activeAgentAgreementKeys(nowMilliseconds: now).map(\.generation), [1, 2])
        XCTAssertEqual(preview.activeAgentAgreementKeys(nowMilliseconds: deadline).map(\.generation), [2])
        keyStore.deleteIdentity(accountID: identity.accountID)
    }

    func testOutboundRotationPromotesOnlyAfterAuthenticatedReceiptToPreparedKEM() async throws {
        let service = "ai.hermes.tests.outbound-rotate.\(UUID().uuidString)"
        let keyStore = RelayV2KeychainStore(service: service, previewAccessGroup: nil)
        var identity = RelayV2Identity.makeUnpaired(accountID: "acc_outbound_rotate")
        let oldDevice = try XCTUnwrap(identity.currentKeys)
        let agent = RelayV2Crypto.generateAgreementKeyPair()
        let agentSigning = RelayV2Crypto.generateSigningKeyPair()
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = agent.publicKey
        identity.agentSigningPublicKey = agentSigning.publicKey
        identity.agentKeyGeneration = 1
        identity.outboundEncryptedMessageCount = RelayV2Client.automaticRotationMessageLimit
        try keyStore.saveIdentity(identity)
        identity = try XCTUnwrap(keyStore.loadIdentity(accountID: identity.accountID))
        try keyStore.savePreviewKey(.init(
            accountID: identity.accountID,
            privateKey: RelayV2Crypto.generateAgreementKeyPair().privateKey,
            agentAgreementPublicKey: agent.publicKey,
            generation: 1
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayV2HubAcceptStub.self]
        RelayV2HubAcceptStub.reset()
        let client = try RelayV2Client(
            identity: identity,
            keyStore: keyStore,
            database: RelayV2Database.inMemory(),
            hub: RelayV2HubTransport(
                configuration: try .init(
                    baseURL: URL(string: "https://relay.example.test")!,
                    routeID: "rte_device",
                    routeSigningPrivateKey: oldDevice.signingPrivateKey
                ),
                session: URLSession(configuration: configuration)
            ),
            workRepository: try WorkRepository(configuration: .init(
                containerURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("relay-v2-outbound-work-\(UUID().uuidString)")
            ))
        )
        try await client.rotateDeviceKeysIfNeeded(overlapMilliseconds: 60_000)
        let notYetRotated = try XCTUnwrap(keyStore.loadIdentity(accountID: identity.accountID))
        let pendingKEM = try XCTUnwrap(
            keyStore.loadPendingLocalRotation(accountID: identity.accountID)
        )
        let preparedIdentity = try XCTUnwrap(pendingKEM.updatedIdentity)
        XCTAssertEqual(notYetRotated.currentGeneration, 1)
        XCTAssertEqual(pendingKEM.purpose, "kem")
        XCTAssertEqual(preparedIdentity.currentGeneration, 2)
        XCTAssertEqual(preparedIdentity.recipientPrivateKeys.keys.sorted(), [1, 2])
        let envelopes = try RelayV2HubAcceptStub.postedBodies.map {
            try RelayV2OuterEnvelope.decodeStrict(from: $0)
        }
        XCTAssertEqual(envelopes.count, 1)
        let receive = RelayV2ReceiveContext(
            expectedDestination: "rte_agent",
            expectedSource: "rte_device",
            nowMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000),
            seenMessageIDs: []
        )
        let first = try RelayV2Crypto.openAuthenticatedEnvelope(
            envelopes[0], recipientPrivateKeys: [1: agent.privateKey],
            senderAgreementPublicKey: try oldDevice.agreementPublicKey,
            senderSigningPublicKey: try oldDevice.signingPublicKey,
            expectedSenderKeyGeneration: 1, purpose: .control,
            direction: .deviceToAgent, receive: receive
        )
        XCTAssertEqual(first.kind, .keyRotate)
        XCTAssertEqual(first.body["purpose"]?.stringValue, "kem")
        let newDevice = try XCTUnwrap(preparedIdentity.currentKeys)

        // The Agent has installed generation 2, so its receipt is encrypted to
        // generation 2. The client can decrypt with the prepared key without
        // treating it as current until this authenticated receipt is applied.
        let kemReceipt = try makeRotationReceipt(
            acknowledgedMessageID: pendingKEM.envelope.header.messageID,
            recipientGeneration: 2,
            recipientPublicKey: try newDevice.agreementPublicKey,
            agentAgreement: agent,
            agentSigning: agentSigning
        )
        try await client.ingest(kemReceipt)
        let rotated = try XCTUnwrap(keyStore.loadIdentity(accountID: identity.accountID))
        XCTAssertEqual(rotated.currentGeneration, 2)
        let pendingPreview = try XCTUnwrap(
            keyStore.loadPendingLocalRotation(accountID: identity.accountID)
        )
        XCTAssertEqual(pendingPreview.purpose, "preview")
        XCTAssertEqual(
            try keyStore.loadPreviewKey(accountID: identity.accountID)?.generation,
            1
        )

        let postedAfterReceipt = try RelayV2HubAcceptStub.postedBodies.map {
            try RelayV2OuterEnvelope.decodeStrict(from: $0)
        }
        XCTAssertEqual(postedAfterReceipt.count, 2)
        let second = try RelayV2Crypto.openAuthenticatedEnvelope(
            postedAfterReceipt[1], recipientPrivateKeys: [1: agent.privateKey],
            senderAgreementPublicKey: try newDevice.agreementPublicKey,
            senderSigningPublicKey: try newDevice.signingPublicKey,
            expectedSenderKeyGeneration: 2, purpose: .control,
            direction: .deviceToAgent, receive: receive
        )
        XCTAssertEqual(second.body["purpose"]?.stringValue, "preview")
        let previewReceipt = try makeRotationReceipt(
            acknowledgedMessageID: pendingPreview.envelope.header.messageID,
            recipientGeneration: 2,
            recipientPublicKey: try newDevice.agreementPublicKey,
            agentAgreement: agent,
            agentSigning: agentSigning
        )
        try await client.ingest(previewReceipt)
        XCTAssertNil(try keyStore.loadPendingLocalRotation(accountID: identity.accountID))
        XCTAssertEqual(
            try keyStore.loadPreviewKey(accountID: identity.accountID)?.generation,
            2
        )
        XCTAssertEqual(
            RelayV2Client.automaticRotationOverlapMilliseconds,
            RelayV2Client.maximumMailboxTTLMilliseconds
                + RelayV2Client.rotationRetryGraceMilliseconds
        )
        keyStore.deleteIdentity(accountID: identity.accountID)
    }

    private func makeRotationReceipt(
        acknowledgedMessageID: String,
        recipientGeneration: UInt32,
        recipientPublicKey: Data,
        agentAgreement: RelayV2RawKeyPair,
        agentSigning: RelayV2RawKeyPair
    ) throws -> RelayV2OuterEnvelope {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let message = try RelayV2SecureMessage(
            messageID: RelayV2Wire.randomMessageID(), kind: .deliveryReceipt,
            senderKeyGeneration: 1, createdAtMilliseconds: now,
            expiresAtMilliseconds: now + 60_000,
            body: ["mid": .string(acknowledgedMessageID)]
        )
        return try RelayV2Crypto.sealAuthenticatedEnvelope(
            header: RelayV2OuterHeader(
                source: "rte_agent", destination: "rte_device",
                messageID: message.messageID, messageClass: .control,
                expiresAtMilliseconds: message.expiresAtMilliseconds,
                recipientKeyGeneration: recipientGeneration
            ),
            message: message,
            recipientPublicKey: recipientPublicKey,
            senderAgreementPrivateKey: agentAgreement.privateKey,
            senderSigningPrivateKey: agentSigning.privateKey,
            purpose: .control,
            direction: .agentToDevice
        )
    }

    func testInterruptedOutboundRotationReplaysExactCiphertextWithoutPrematurePromotion() async throws {
        let service = "ai.hermes.tests.rotate-restart.\(UUID().uuidString)"
        let keyStore = RelayV2KeychainStore(service: service, previewAccessGroup: nil)
        var identity = RelayV2Identity.makeUnpaired(accountID: "acc_rotate_restart")
        let agent = RelayV2Crypto.generateAgreementKeyPair()
        identity.hubURL = URL(string: "https://relay.example.test")
        identity.routeID = "rte_device"
        identity.agentRouteID = "rte_agent"
        identity.agentAgreementPublicKey = agent.publicKey
        identity.agentSigningPublicKey = RelayV2Crypto.generateSigningKeyPair().publicKey
        identity.agentKeyGeneration = 1
        try keyStore.saveIdentity(identity)
        try keyStore.savePreviewKey(.init(
            accountID: identity.accountID,
            privateKey: RelayV2Crypto.generateAgreementKeyPair().privateKey,
            agentAgreementPublicKey: agent.publicKey,
            generation: 1
        ))
        let database = try RelayV2Database.inMemory()
        let repository = try WorkRepository(configuration: .init(
            containerURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-v2-rotate-restart-work-\(UUID().uuidString)")
        ))
        let failureConfiguration = URLSessionConfiguration.ephemeral
        failureConfiguration.protocolClasses = [RelayV2HubErrorStub.self]
        RelayV2HubErrorStub.status = 503
        RelayV2HubErrorStub.headers = ["Content-Type": "application/json"]
        RelayV2HubErrorStub.body = Data(
            "{\"error\":{\"code\":\"GATEWAY_OFFLINE\",\"message\":\"offline\"}}".utf8
        )
        let firstClient = try RelayV2Client(
            identity: identity, keyStore: keyStore, database: database,
            hub: RelayV2HubTransport(
                configuration: try .init(
                    baseURL: URL(string: "https://relay.example.test")!,
                    routeID: "rte_device",
                    routeSigningPrivateKey: try XCTUnwrap(identity.currentKeys).signingPrivateKey
                ),
                session: URLSession(configuration: failureConfiguration)
            ),
            workRepository: repository
        )
        await XCTAssertThrowsErrorAsync {
            try await firstClient.rotateDeviceKeysIfNeeded(
                maximumAgeMilliseconds: 0,
                overlapMilliseconds: 60_000
            )
        }
        let prepared = try XCTUnwrap(keyStore.loadIdentity(accountID: identity.accountID))
        XCTAssertEqual(prepared.currentGeneration, 1)
        XCTAssertNotNil(try keyStore.loadPendingLocalRotation(accountID: identity.accountID))

        let successConfiguration = URLSessionConfiguration.ephemeral
        successConfiguration.protocolClasses = [RelayV2HubAcceptStub.self]
        RelayV2HubAcceptStub.reset()
        let recoveredClient = try RelayV2Client(
            identity: prepared, keyStore: keyStore, database: database,
            hub: RelayV2HubTransport(
                configuration: try .init(
                    baseURL: URL(string: "https://relay.example.test")!,
                    routeID: "rte_device",
                    routeSigningPrivateKey: try XCTUnwrap(prepared.currentKeys).signingPrivateKey
                ),
                session: URLSession(configuration: successConfiguration)
            ),
            workRepository: repository
        )
        try await recoveredClient.recoverPendingLocalRotation()
        XCTAssertNotNil(try keyStore.loadPendingLocalRotation(accountID: identity.accountID))
        XCTAssertEqual(
            try keyStore.loadIdentity(accountID: identity.accountID)?.currentGeneration,
            1
        )
        XCTAssertEqual(RelayV2HubAcceptStub.postedBodies.count, 1)
        try await recoveredClient.recoverPendingLocalRotation()
        XCTAssertEqual(RelayV2HubAcceptStub.postedBodies.count, 2)
        XCTAssertEqual(
            RelayV2HubAcceptStub.postedBodies[0],
            RelayV2HubAcceptStub.postedBodies[1]
        )
        keyStore.deleteIdentity(accountID: identity.accountID)
    }
}

final class RelayV2PushCrashRecoveryTests: XCTestCase {
    private actor Attester: RelayV2AppAttesting {
        nonisolated let isSupported = true
        private var keyCount = 0
        func generateKey() async throws -> String {
            keyCount += 1
            return "attest_key_\(keyCount)"
        }
        func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
            Data(repeating: 0xA1, count: 48)
        }
        func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
            Data(repeating: 0xB2, count: 48)
        }
    }

    @MainActor
    func testCommittedV2EndpointOwnsAlertAuthorityAndStablePrivateScope() throws {
        let defaults = UserDefaults.standard
        let priorTransport = defaults.object(forKey: DefaultsKeys.transportPath)
        let priorAccount = defaults.object(forKey: DefaultsKeys.relayV2AccountID)
        let priorEnabled = defaults.object(forKey: DefaultsKeys.pushEnabled)
        let priorHealthy = defaults.object(forKey: DefaultsKeys.pushRegistrationHealthy)
        defer {
            for (key, value) in [
                (DefaultsKeys.transportPath, priorTransport),
                (DefaultsKeys.relayV2AccountID, priorAccount),
                (DefaultsKeys.pushEnabled, priorEnabled),
                (DefaultsKeys.pushRegistrationHealthy, priorHealthy),
            ] {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let accountID = "acc_push_authority_\(UUID().uuidString.lowercased())"
        let keyStore = RelayV2KeychainStore()
        defer { keyStore.deleteEnrollmentState(accountID: accountID) }
        defaults.set(TransportPath.relayV2.rawValue, forKey: DefaultsKeys.transportPath)
        defaults.set(accountID, forKey: DefaultsKeys.relayV2AccountID)
        defaults.set(true, forKey: DefaultsKeys.pushEnabled)
        defaults.set(true, forKey: DefaultsKeys.pushRegistrationHealthy)
        try keyStore.savePushRegistrationState(.init(
            accountID: accountID,
            endpointID: "end_authoritative",
            appAttestKeyID: "attest_authoritative",
            pendingAttestation: nil,
            pendingRequestBody: nil,
            pendingRequestExpiresAtMilliseconds: nil,
            attestationPhase: .committed,
            installationNonce: Data(repeating: 1, count: 32),
            previewPublicKey: Data(repeating: 2, count: 32),
            environment: .sandbox
        ))

        let registrar = PushRegistrar()
        XCTAssertTrue(registrar.isAlertAuthorityRegistered)
        let scope = try XCTUnwrap(registrar.notificationScope)
        XCTAssertFalse(scope.contains(accountID))
        XCTAssertEqual(scope, registrar.notificationScope)

        try keyStore.savePushRegistrationState(.init(
            accountID: accountID,
            endpointID: nil,
            appAttestKeyID: "attest_pending",
            pendingAttestation: nil,
            pendingRequestBody: nil,
            pendingRequestExpiresAtMilliseconds: nil,
            attestationPhase: .requestReady,
            installationNonce: Data(repeating: 1, count: 32),
            previewPublicKey: Data(repeating: 2, count: 32),
            environment: .sandbox
        ))
        XCTAssertFalse(registrar.isAlertAuthorityRegistered)
    }

    func testPairingEnrollmentStateMigratesToDurableAccountAndDeletesTemporaryKeys() throws {
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.push.migrate.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        let temporary = "pairing_offer"
        try keyStore.savePushRegistrationState(.init(
            accountID: temporary, endpointID: "endpoint", appAttestKeyID: "attest",
            pendingAttestation: Data("attestation".utf8),
            pendingRequestBody: Data("request-with-apns".utf8),
            pendingRequestExpiresAtMilliseconds: 999, attestationPhase: .committed,
            installationNonce: Data(repeating: 1, count: 32),
            previewPublicKey: Data(repeating: 2, count: 32), environment: .sandbox,
            committedResponseData: Data("bind-and-activation".utf8)
        ))
        try keyStore.saveHubActivationState(.init(
            accountID: temporary, appAttestKeyID: "activation", isAttested: true,
            pendingAttestation: Data("activation-attestation".utf8),
            pendingRequestBody: Data("activation-request".utf8),
            pendingRequestExpiresAtMilliseconds: 999, attestationPhase: .committed,
            installationNonce: Data(repeating: 3, count: 32), environment: .sandbox,
            committedResponseData: Data("activation-token".utf8)
        ))

        try keyStore.migrateEnrollmentState(from: temporary, to: "acc_durable")

        XCTAssertEqual(
            try keyStore.loadPushRegistrationState(accountID: "acc_durable")?.endpointID,
            "endpoint"
        )
        XCTAssertTrue(
            try XCTUnwrap(keyStore.loadHubActivationState(accountID: "acc_durable")).isAttested
        )
        let durablePush = try XCTUnwrap(
            keyStore.loadPushRegistrationState(accountID: "acc_durable")
        )
        XCTAssertNil(durablePush.pendingAttestation)
        XCTAssertNil(durablePush.pendingRequestBody)
        XCTAssertNil(durablePush.pendingRequestExpiresAtMilliseconds)
        XCTAssertNil(durablePush.committedResponseData)
        let durableActivation = try XCTUnwrap(
            keyStore.loadHubActivationState(accountID: "acc_durable")
        )
        XCTAssertNil(durableActivation.pendingAttestation)
        XCTAssertNil(durableActivation.pendingRequestBody)
        XCTAssertNil(durableActivation.pendingRequestExpiresAtMilliseconds)
        XCTAssertNil(durableActivation.committedResponseData)
        XCTAssertNil(try keyStore.loadPushRegistrationState(accountID: temporary))
        XCTAssertNil(try keyStore.loadHubActivationState(accountID: temporary))
        keyStore.deleteEnrollmentState(accountID: "acc_durable")
    }

    func testPersistedAppAttestCallBoundariesChooseOnlySafeKey() async throws {
        for (phase, expectedKey) in [
            (RelayV2AttestationPhase.keyGenerated, "persisted_key"),
            (.attestationStarted, "attest_key_1"),
            (.attestationReturned, "attest_key_1"),
        ] {
            RelayV2PushStub.reset()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RelayV2PushStub.self]
            let session = URLSession(configuration: config)
            let keyStore = RelayV2KeychainStore(
                service: "ai.hermes.tests.push.phase.\(phase.rawValue).\(UUID().uuidString)",
                previewAccessGroup: nil
            )
            var state = RelayV2PushRegistrationState(
                accountID: "acc_phase", endpointID: nil, appAttestKeyID: "persisted_key",
                pendingAttestation: phase == .attestationReturned ? Data(repeating: 0xA1, count: 48) : nil,
                pendingRequestBody: nil, pendingRequestExpiresAtMilliseconds: nil,
                installationNonce: Data(repeating: 3, count: 32),
                previewPublicKey: Data(repeating: 2, count: 32), environment: .sandbox
            )
            state.attestationPhase = phase
            try keyStore.savePushRegistrationState(state)
            let client = try RelayV2PushRegistrationClient(
                baseURL: URL(string: "https://push.example.test")!, session: session,
                appAttest: Attester(), keyStore: keyStore
            )

            await XCTAssertThrowsErrorAsync {
                _ = try await client.register(
                    accountID: "acc_phase", apnsToken: Data(repeating: 1, count: 32),
                    environment: .sandbox, bundleID: "ai.hermes.app",
                    previewKEMPublicKey: Data(repeating: 2, count: 32),
                    installationNonce: Data(repeating: 3, count: 32), hubRouteID: "rte_agent"
                )
            }

            let body = try XCTUnwrap(RelayV2PushStub.registrationBodies.first)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(object["app_attest_key_id"] as? String, expectedKey)
            XCTAssertTrue(object["attestation"] is String)
            XCTAssertEqual(
                try keyStore.loadPushRegistrationState(accountID: "acc_phase")?.attestationPhase,
                .requestReady
            )
        }
    }

    func testResponseLossReplaysExactRegistrationBodyAfterRestart() async throws {
        RelayV2PushStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayV2PushStub.self]
        let session = URLSession(configuration: config)
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.push.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        let attester = Attester()
        let first = try RelayV2PushRegistrationClient(
            baseURL: URL(string: "https://push.example.test")!, session: session,
            appAttest: attester, keyStore: keyStore
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await first.register(
                accountID: "acc_push", apnsToken: Data(repeating: 1, count: 32),
                environment: .sandbox, bundleID: "ai.hermes.app",
                previewKEMPublicKey: Data(repeating: 2, count: 32),
                installationNonce: Data(repeating: 3, count: 32), hubRouteID: "rte_agent"
            )
        }
        XCTAssertEqual(
            RelayV2PushStub.challengeRequests, 1,
            "requests: \(RelayV2PushStub.requestedURLs)"
        )
        XCTAssertEqual(RelayV2PushStub.registrationBodies.count, 1)

        let restarted = try RelayV2PushRegistrationClient(
            baseURL: URL(string: "https://push.example.test")!, session: session,
            appAttest: attester, keyStore: keyStore
        )
        let result = try await restarted.register(
            accountID: "acc_push", apnsToken: Data(repeating: 1, count: 32),
            environment: .sandbox, bundleID: "ai.hermes.app",
            previewKEMPublicKey: Data(repeating: 2, count: 32),
            installationNonce: Data(repeating: 3, count: 32), hubRouteID: "rte_agent"
        )
        XCTAssertEqual(result.endpointID, "ep_test")
        XCTAssertEqual(RelayV2PushStub.challengeRequests, 1)
        XCTAssertEqual(RelayV2PushStub.registrationBodies.count, 2)
        XCTAssertEqual(RelayV2PushStub.registrationBodies[0], RelayV2PushStub.registrationBodies[1])
    }

    func testCommittedEnrollmentReceiptReturnsTokensWithoutNewRegistration() async throws {
        RelayV2PushStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayV2PushStub.self]
        let session = URLSession(configuration: config)
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.push.committed-receipt.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        let attester = Attester()
        let first = try RelayV2PushRegistrationClient(
            baseURL: URL(string: "https://push.example.test")!, session: session,
            appAttest: attester, keyStore: keyStore
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await first.register(
                accountID: "acc_receipt", apnsToken: Data(repeating: 1, count: 32),
                environment: .sandbox, bundleID: "ai.hermes.app",
                previewKEMPublicKey: Data(repeating: 2, count: 32),
                installationNonce: Data(repeating: 3, count: 32), hubRouteID: "rte_agent"
            )
        }
        let committed = try await first.register(
            accountID: "acc_receipt", apnsToken: Data(repeating: 1, count: 32),
            environment: .sandbox, bundleID: "ai.hermes.app",
            previewKEMPublicKey: Data(repeating: 2, count: 32),
            installationNonce: Data(repeating: 3, count: 32), hubRouteID: "rte_agent"
        )
        XCTAssertEqual(RelayV2PushStub.challengeRequests, 1)
        XCTAssertEqual(RelayV2PushStub.registrationBodies.count, 2)

        // Simulate termination after register() committed its local receipt but
        // before the pairing coordinator persisted PairInit.
        let restarted = try RelayV2PushRegistrationClient(
            baseURL: URL(string: "https://push.example.test")!, session: session,
            appAttest: attester, keyStore: keyStore
        )
        let recovered = try await restarted.register(
            accountID: "acc_receipt", apnsToken: Data(repeating: 1, count: 32),
            environment: .sandbox, bundleID: "ai.hermes.app",
            previewKEMPublicKey: Data(repeating: 2, count: 32),
            installationNonce: Data(repeating: 3, count: 32), hubRouteID: "rte_agent"
        )
        XCTAssertEqual(recovered, committed)
        XCTAssertEqual(RelayV2PushStub.challengeRequests, 1)
        XCTAssertEqual(
            RelayV2PushStub.registrationBodies.count,
            2,
            "restart must recover the committed token receipt without registering again"
        )
    }

    func testCommittedHubActivationReceiptReturnsTokenWithoutNewActivation() async throws {
        RelayV2PushStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayV2PushStub.self]
        let session = URLSession(configuration: config)
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.activation.committed-receipt.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        let attester = Attester()
        let first = try RelayV2PushRegistrationClient(
            baseURL: URL(string: "https://push.example.test")!, session: session,
            appAttest: attester, keyStore: keyStore
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await first.activateHub(
                accountID: "acc_activation_receipt", environment: .sandbox,
                bundleID: "ai.hermes.app", installationNonce: Data(repeating: 3, count: 32),
                hubRouteID: "rte_agent"
            )
        }
        let committed = try await first.activateHub(
            accountID: "acc_activation_receipt", environment: .sandbox,
            bundleID: "ai.hermes.app", installationNonce: Data(repeating: 3, count: 32),
            hubRouteID: "rte_agent"
        )
        XCTAssertEqual(RelayV2PushStub.challengeRequests, 1)
        XCTAssertEqual(RelayV2PushStub.activationBodies.count, 2)

        let restarted = try RelayV2PushRegistrationClient(
            baseURL: URL(string: "https://push.example.test")!, session: session,
            appAttest: attester, keyStore: keyStore
        )
        let recovered = try await restarted.activateHub(
            accountID: "acc_activation_receipt", environment: .sandbox,
            bundleID: "ai.hermes.app", installationNonce: Data(repeating: 3, count: 32),
            hubRouteID: "rte_agent"
        )
        XCTAssertEqual(recovered, committed)
        XCTAssertEqual(RelayV2PushStub.challengeRequests, 1)
        XCTAssertEqual(RelayV2PushStub.activationBodies.count, 2)
    }

    func testExpiredLostResponseRecoversOriginalCommittedKeyBeforeFreshEnrollment() async throws {
        RelayV2PushStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayV2PushStub.self]
        let session = URLSession(configuration: config)
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.push.expired.\(UUID().uuidString)", previewAccessGroup: nil
        )
        let attester = Attester()
        let client = try RelayV2PushRegistrationClient(
            baseURL: URL(string: "https://push.example.test")!, session: session,
            appAttest: attester, keyStore: keyStore
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await client.register(
                accountID: "acc_expired", apnsToken: Data(repeating: 1, count: 32),
                environment: .sandbox, bundleID: "ai.hermes.app",
                previewKEMPublicKey: Data(repeating: 2, count: 32),
                installationNonce: Data(repeating: 3, count: 32), hubRouteID: "rte_agent"
            )
        }
        var pending = try XCTUnwrap(keyStore.loadPushRegistrationState(accountID: "acc_expired"))
        let originalKey = pending.appAttestKeyID
        pending.pendingRequestExpiresAtMilliseconds = 1
        try keyStore.savePushRegistrationState(pending)

        let result = try await client.register(
            accountID: "acc_expired", apnsToken: Data(repeating: 1, count: 32),
            environment: .sandbox, bundleID: "ai.hermes.app",
            previewKEMPublicKey: Data(repeating: 2, count: 32),
            installationNonce: Data(repeating: 3, count: 32), hubRouteID: "rte_agent"
        )
        XCTAssertEqual(result.endpointID, "ep_test")
        XCTAssertEqual(try keyStore.loadPushRegistrationState(accountID: "acc_expired")?.appAttestKeyID, originalKey)
        XCTAssertEqual(RelayV2PushStub.challengeRequests, 2)
        let recovery = try JSONSerialization.jsonObject(
            with: RelayV2PushStub.registrationBodies[1]
        ) as! [String: Any]
        XCTAssertTrue(recovery["attestation"] is NSNull)
    }

    func testExpiredUncommittedKeyRequiresTypedProofBeforeFreshAttestation() async throws {
        RelayV2PushStub.reset()
        RelayV2PushStub.initialRequiredOnSecondRegistration = true
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayV2PushStub.self]
        let session = URLSession(configuration: config)
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.push.uncommitted.\(UUID().uuidString)", previewAccessGroup: nil
        )
        let attester = Attester()
        let client = try RelayV2PushRegistrationClient(
            baseURL: URL(string: "https://push.example.test")!, session: session,
            appAttest: attester, keyStore: keyStore
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await client.register(
                accountID: "acc_uncommitted", apnsToken: Data(repeating: 1, count: 32),
                environment: .sandbox, bundleID: "ai.hermes.app",
                previewKEMPublicKey: Data(repeating: 2, count: 32),
                installationNonce: Data(repeating: 3, count: 32), hubRouteID: "rte_agent"
            )
        }
        var pending = try XCTUnwrap(keyStore.loadPushRegistrationState(accountID: "acc_uncommitted"))
        let originalKey = pending.appAttestKeyID
        pending.pendingRequestExpiresAtMilliseconds = 1
        try keyStore.savePushRegistrationState(pending)
        _ = try await client.register(
            accountID: "acc_uncommitted", apnsToken: Data(repeating: 1, count: 32),
            environment: .sandbox, bundleID: "ai.hermes.app",
            previewKEMPublicKey: Data(repeating: 2, count: 32),
            installationNonce: Data(repeating: 3, count: 32), hubRouteID: "rte_agent"
        )
        let final = try XCTUnwrap(keyStore.loadPushRegistrationState(accountID: "acc_uncommitted"))
        XCTAssertNotEqual(final.appAttestKeyID, originalKey)
        XCTAssertEqual(RelayV2PushStub.registrationBodies.count, 3)
        let recovery = try JSONSerialization.jsonObject(with: RelayV2PushStub.registrationBodies[1]) as! [String: Any]
        let fresh = try JSONSerialization.jsonObject(with: RelayV2PushStub.registrationBodies[2]) as! [String: Any]
        XCTAssertTrue(recovery["attestation"] is NSNull)
        XCTAssertTrue(fresh["attestation"] is String)
    }

    func testExpiredActivationUsesOriginalKeyThenFreshKeyOnlyAfterTypedProof() async throws {
        RelayV2PushStub.reset()
        RelayV2PushStub.initialRequiredOnSecondActivation = true
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayV2PushStub.self]
        let session = URLSession(configuration: config)
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.activation.\(UUID().uuidString)", previewAccessGroup: nil
        )
        let attester = Attester()
        let client = try RelayV2PushRegistrationClient(
            baseURL: URL(string: "https://push.example.test")!, session: session,
            appAttest: attester, keyStore: keyStore
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await client.activateHub(
                accountID: "acc_activation", environment: .sandbox,
                bundleID: "ai.hermes.app", installationNonce: Data(repeating: 3, count: 32),
                hubRouteID: "rte_agent"
            )
        }
        var pending = try XCTUnwrap(keyStore.loadHubActivationState(accountID: "acc_activation"))
        let originalKey = pending.appAttestKeyID
        pending.pendingRequestExpiresAtMilliseconds = 1
        try keyStore.saveHubActivationState(pending)
        let result = try await client.activateHub(
            accountID: "acc_activation", environment: .sandbox,
            bundleID: "ai.hermes.app", installationNonce: Data(repeating: 3, count: 32),
            hubRouteID: "rte_agent"
        )
        XCTAssertEqual(result.token, "activate_test")
        XCTAssertNotEqual(
            try keyStore.loadHubActivationState(accountID: "acc_activation")?.appAttestKeyID,
            originalKey
        )
        XCTAssertEqual(RelayV2PushStub.activationBodies.count, 3)
        let recovery = try JSONSerialization.jsonObject(with: RelayV2PushStub.activationBodies[1]) as! [String: Any]
        let fresh = try JSONSerialization.jsonObject(with: RelayV2PushStub.activationBodies[2]) as! [String: Any]
        XCTAssertTrue(recovery["attestation"] is NSNull)
        XCTAssertTrue(fresh["attestation"] is String)
    }

    func testExpiredActivationRecoversCommittedOriginalKeyWithoutFreshEnrollment() async throws {
        RelayV2PushStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayV2PushStub.self]
        let session = URLSession(configuration: config)
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.activation.committed.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        let client = try RelayV2PushRegistrationClient(
            baseURL: URL(string: "https://push.example.test")!, session: session,
            appAttest: Attester(), keyStore: keyStore
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await client.activateHub(
                accountID: "acc_activation_committed", environment: .sandbox,
                bundleID: "ai.hermes.app", installationNonce: Data(repeating: 3, count: 32),
                hubRouteID: "rte_agent"
            )
        }
        var pending = try XCTUnwrap(
            keyStore.loadHubActivationState(accountID: "acc_activation_committed")
        )
        let originalKey = pending.appAttestKeyID
        pending.pendingRequestExpiresAtMilliseconds = 1
        try keyStore.saveHubActivationState(pending)

        let result = try await client.activateHub(
            accountID: "acc_activation_committed", environment: .sandbox,
            bundleID: "ai.hermes.app", installationNonce: Data(repeating: 3, count: 32),
            hubRouteID: "rte_agent"
        )
        XCTAssertEqual(result.token, "activate_test")
        XCTAssertEqual(
            try keyStore.loadHubActivationState(accountID: "acc_activation_committed")?.appAttestKeyID,
            originalKey
        )
        XCTAssertEqual(RelayV2PushStub.activationBodies.count, 2)
        let recovery = try JSONSerialization.jsonObject(
            with: RelayV2PushStub.activationBodies[1]
        ) as! [String: Any]
        XCTAssertTrue(recovery["attestation"] is NSNull)
    }

    func testPreviewPolicyMovesKeyOutOfAndBackIntoExtensionScope() throws {
        let keyStore = RelayV2KeychainStore(
            service: "ai.hermes.tests.preview.\(UUID().uuidString)",
            previewAccessGroup: nil
        )
        let record = RelayV2PreviewKeyRecord(
            accountID: "acc_preview", privateKey: Data(repeating: 1, count: 32),
            agentAgreementPublicKey: Data(repeating: 2, count: 32), generation: 1
        )
        try keyStore.savePreviewKey(record, policy: .afterFirstUnlock)
        XCTAssertEqual(try keyStore.loadPreviewKey(accountID: record.accountID), record)
        try keyStore.applyPreviewPolicy(.disabled, accountID: record.accountID)
        XCTAssertNil(try keyStore.loadPreviewKey(accountID: record.accountID))
        try keyStore.applyPreviewPolicy(.whenUnlocked, accountID: record.accountID)
        XCTAssertEqual(try keyStore.loadPreviewKey(accountID: record.accountID), record)
        keyStore.deleteIdentity(accountID: record.accountID)
    }
}

private final class RelayV2PushStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var challengeRequests = 0
    nonisolated(unsafe) static var registrationBodies: [Data] = []
    nonisolated(unsafe) static var requestedURLs: [String] = []
    nonisolated(unsafe) static var initialRequiredOnSecondRegistration = false
    nonisolated(unsafe) static var activationBodies: [Data] = []
    nonisolated(unsafe) static var initialRequiredOnSecondActivation = false

    static func reset() {
        challengeRequests = 0
        registrationBodies = []
        requestedURLs = []
        initialRequiredOnSecondRegistration = false
        activationBodies = []
        initialRequiredOnSecondActivation = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requestedURLs.append(url.absoluteString)
        if url.absoluteString.contains("/v2/attest/challenge") {
            Self.challengeRequests += 1
            let challenge = RelayV2Wire.base64URL(Data(repeating: 0xCC, count: 32))
            respond(200, Data("{\"challenge\":\"\(challenge)\",\"expires_at_ms\":9999999999999}".utf8))
            return
        }
        if url.absoluteString.contains("/v2/endpoints/register"), let body = Self.bodyData(request) {
            Self.registrationBodies.append(body)
            if Self.registrationBodies.count == 1 {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else if Self.registrationBodies.count == 2,
                      Self.initialRequiredOnSecondRegistration {
                respond(409, Data("{\"error\":{\"code\":\"app_attest_initial_required\",\"message\":\"initial attestation required\"}}".utf8))
            } else {
                let bind = RelayV2Wire.base64URL(Data(repeating: 4, count: 32))
                respond(200, Data("{\"endpoint_id\":\"ep_test\",\"bind_token\":\"\(bind)\",\"bind_token_expires_at_ms\":9999999999999,\"hub_activation_token\":\"activate_test\",\"hub_activation_token_expires_at_ms\":9999999999999}".utf8))
            }
            return
        }
        if url.absoluteString.contains("/v2/hub-activations"), let body = Self.bodyData(request) {
            Self.activationBodies.append(body)
            if Self.activationBodies.count == 1 {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else if Self.activationBodies.count == 2,
                      Self.initialRequiredOnSecondActivation {
                respond(409, Data("{\"error\":{\"code\":\"app_attest_initial_required\",\"message\":\"initial attestation required\"}}".utf8))
            } else {
                respond(200, Data("{\"hub_activation_token\":\"activate_test\",\"hub_activation_token_expires_at_ms\":9999999999999}".utf8))
            }
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
    }

    private func respond(_ status: Int, _ data: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            output.append(buffer, count: count)
        }
        return output
    }

    override func stopLoading() {}
}

private final class RelayV2HubErrorStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 500
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil,
            headerFields: Self.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RelayV2HubAcceptStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var postedBodies: [Data] = []
    nonisolated(unsafe) static var acknowledgementCount = 0
    nonisolated(unsafe) static var responseDelay: TimeInterval = 0
    nonisolated(unsafe) static var maximumConcurrentPosts = 0
    nonisolated(unsafe) static var onPost: (@Sendable (RelayV2OuterEnvelope) -> Void)?
    nonisolated(unsafe) private static var activePosts = 0
    private static let stateLock = NSLock()

    static func reset() {
        stateLock.lock()
        postedBodies = []
        acknowledgementCount = 0
        responseDelay = 0
        maximumConcurrentPosts = 0
        activePosts = 0
        onPost = nil
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            if request.url?.path == "/v2/acks" {
                Self.stateLock.lock()
                Self.acknowledgementCount += 1
                Self.stateLock.unlock()
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            guard let body = Self.bodyData(request) else {
                throw URLError(.cannotDecodeContentData)
            }
            let envelope = try RelayV2OuterEnvelope.decodeStrict(from: body)
            Self.stateLock.lock()
            Self.postedBodies.append(body)
            Self.activePosts += 1
            Self.maximumConcurrentPosts = max(Self.maximumConcurrentPosts, Self.activePosts)
            let delay = Self.responseDelay
            let onPost = Self.onPost
            Self.stateLock.unlock()
            onPost?(envelope)
            let finish: @Sendable () -> Void = { [self] in
                do {
                    let responseBody = try RelayV2Wire.canonicalJSON([
                        "accepted": true,
                        "deduplicated": false,
                        "stored": true,
                        "mid": .string(envelope.header.messageID),
                    ] as [String: JSONValue])
                    let response = HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: responseBody)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
                Self.stateLock.lock()
                Self.activePosts -= 1
                Self.stateLock.unlock()
            }
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: finish)
            } else {
                finish()
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }
}

private final class RelayV2LifecyclePostStub: URLProtocol, @unchecked Sendable {
    struct Snapshot {
        let posts: Int
        let activePosts: Int
        let maximumConcurrentPosts: Int
    }

    nonisolated(unsafe) private static var posts = 0
    nonisolated(unsafe) private static var activePosts = 0
    nonisolated(unsafe) private static var maximumConcurrentPosts = 0
    nonisolated(unsafe) private static var gate: RelayV2LifecyclePostGate?
    private static let stateLock = NSLock()
    private var countedAsActive = false

    static func reset(gate: RelayV2LifecyclePostGate) {
        stateLock.lock()
        posts = 0
        activePosts = 0
        maximumConcurrentPosts = 0
        self.gate = gate
        stateLock.unlock()
    }

    static func snapshot() -> Snapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Snapshot(
            posts: posts,
            activePosts: activePosts,
            maximumConcurrentPosts: maximumConcurrentPosts
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/v2/messages"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let body = Self.bodyData(request) else {
                throw URLError(.cannotDecodeContentData)
            }
            let envelope = try RelayV2OuterEnvelope.decodeStrict(from: body)
            Self.stateLock.lock()
            Self.posts += 1
            let ordinal = Self.posts
            Self.activePosts += 1
            Self.maximumConcurrentPosts = max(
                Self.maximumConcurrentPosts,
                Self.activePosts
            )
            countedAsActive = true
            let gate = Self.gate
            Self.stateLock.unlock()

            if ordinal == 1 {
                // Hold the first request until URLSession cancellation invokes
                // stopLoading. This makes disconnect's HTTP fence observable.
                Task { await gate?.recordFirstPostStarted() }
                return
            }

            let responseBody = try RelayV2Wire.canonicalJSON([
                "accepted": true,
                "deduplicated": false,
                "stored": true,
                "mid": .string(envelope.header.messageID),
            ] as [String: JSONValue])
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
            finishActiveRequest()
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            finishActiveRequest()
        }
    }

    override func stopLoading() {
        finishActiveRequest()
    }

    private func finishActiveRequest() {
        Self.stateLock.lock()
        if countedAsActive {
            countedAsActive = false
            Self.activePosts -= 1
        }
        Self.stateLock.unlock()
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }
}

private final class RelayV2RevokedThenAcceptStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var storedPostCount = 0
    private static let stateLock = NSLock()

    static var postCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedPostCount
    }

    static func reset() {
        stateLock.lock()
        storedPostCount = 0
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/v2/messages"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let body = Self.bodyData(request) else {
                throw URLError(.cannotDecodeContentData)
            }
            let envelope = try RelayV2OuterEnvelope.decodeStrict(from: body)
            Self.stateLock.lock()
            Self.storedPostCount += 1
            let ordinal = Self.storedPostCount
            Self.stateLock.unlock()

            let status: Int
            let responseBody: Data
            if ordinal == 1 {
                status = 403
                responseBody = Data(
                    #"{"error":{"code":"REVOKED","message":"device revoked"}}"#.utf8
                )
            } else {
                status = 200
                responseBody = try RelayV2Wire.canonicalJSON([
                    "accepted": true,
                    "deduplicated": false,
                    "stored": true,
                    "mid": .string(envelope.header.messageID),
                ] as [String: JSONValue])
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }
}

private final class RelayV2PairingStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else {
            throw RelayV2ProtocolError.invalidArgument(field: "hex")
        }
        var output = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else {
                throw RelayV2ProtocolError.invalidArgument(field: "hex")
            }
            output.append(byte)
            index = end
        }
        self = output
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
