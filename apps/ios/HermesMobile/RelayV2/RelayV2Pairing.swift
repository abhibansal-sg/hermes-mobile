import Combine
import CryptoKit
import Foundation

struct RelayV2PairingOffer: Codable, Equatable, Sendable {
    private struct AuthenticatedFields: Encodable {
        let version: Int
        let offerID: String
        let offerRoute: String
        let relayRoute: String
        let expiresAtMilliseconds: UInt64

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case offerID = "offer_id"
            case offerRoute = "offer_route"
            case relayRoute = "relay_route"
            case expiresAtMilliseconds = "expires_at_ms"
        }
    }

    let version: Int
    let hubURL: URL
    let relayRoute: String
    let offerRoute: String
    let offerID: String
    let offerTransportToken: Data
    let expiresAtMilliseconds: UInt64
    let relayAgreementPublicKey: Data
    let relaySigningPublicKey: Data
    let pairSecret: Data

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version = "v"; case hubURL = "hub"; case relayRoute = "relay_route"
        case offerRoute = "offer_route"; case offerID = "offer_id"
        case offerTransportToken = "offer_transport_token"
        case expiresAtMilliseconds = "expires_at_ms"
        case relayAgreementPublicKey = "relay_kem_pub"
        case relaySigningPublicKey = "relay_sign_pub"; case pairSecret = "pair_secret"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        hubURL = try c.decode(URL.self, forKey: .hubURL)
        relayRoute = try c.decode(String.self, forKey: .relayRoute)
        offerRoute = try c.decode(String.self, forKey: .offerRoute)
        offerID = try c.decode(String.self, forKey: .offerID)
        offerTransportToken = try RelayV2Wire.decodeBase64URL(
            c.decode(String.self, forKey: .offerTransportToken), exactBytes: 32
        )
        expiresAtMilliseconds = try c.decode(UInt64.self, forKey: .expiresAtMilliseconds)
        relayAgreementPublicKey = try RelayV2Wire.decodeBase64URL(
            c.decode(String.self, forKey: .relayAgreementPublicKey), exactBytes: 32
        )
        relaySigningPublicKey = try RelayV2Wire.decodeBase64URL(
            c.decode(String.self, forKey: .relaySigningPublicKey), exactBytes: 32
        )
        pairSecret = try RelayV2Wire.decodeBase64URL(
            c.decode(String.self, forKey: .pairSecret), exactBytes: 32
        )
        guard version == 2, hubURL.scheme == "https", RelayV2Wire.isToken(relayRoute),
              RelayV2Wire.isToken(offerRoute), RelayV2Wire.isToken(offerID),
              expiresAtMilliseconds <= RelayV2.maximumJSONInteger else {
            throw RelayV2ProtocolError.invalidArgument(field: "pairing_offer")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(hubURL, forKey: .hubURL)
        try c.encode(relayRoute, forKey: .relayRoute); try c.encode(offerRoute, forKey: .offerRoute)
        try c.encode(offerID, forKey: .offerID)
        try c.encode(RelayV2Wire.base64URL(offerTransportToken), forKey: .offerTransportToken)
        try c.encode(expiresAtMilliseconds, forKey: .expiresAtMilliseconds)
        try c.encode(RelayV2Wire.base64URL(relayAgreementPublicKey), forKey: .relayAgreementPublicKey)
        try c.encode(RelayV2Wire.base64URL(relaySigningPublicKey), forKey: .relaySigningPublicKey)
        try c.encode(RelayV2Wire.base64URL(pairSecret), forKey: .pairSecret)
    }

    static func decodeScannerPayload(_ value: String) throws -> Self {
        guard !value.contains("?"), let data = value.data(using: .utf8) else {
            throw RelayV2ProtocolError.invalidArgument(field: "pairing_qr")
        }
        try RelayV2Wire.requireExactObjectKeys(data, keys: Set(CodingKeys.allCases.map(\.rawValue)))
        try RelayV2Wire.requireNoFloatingPointJSON(from: data)
        try RelayV2Wire.requireSharedIntegerRange(from: data)
        return try JSONDecoder().decode(Self.self, from: data)
    }

    var authenticatedData: Data {
        get throws {
            try RelayV2Wire.canonicalJSON(AuthenticatedFields(
                version: 2,
                offerID: offerID,
                offerRoute: offerRoute,
                relayRoute: relayRoute,
                expiresAtMilliseconds: expiresAtMilliseconds
            ))
        }
    }
}

struct RelayV2PairInit: Codable, Equatable, Sendable {
    let offerID: String; let deviceName: String
    let deviceAgreementPublicKey: Data; let deviceSigningPublicKey: Data
    let previewPublicKey: Data; let deviceNonce: Data
    let pushBindToken: String?; let hubActivationToken: String?; let pairMAC: Data

    var transcript: [String: JSONValue] {
        ["v": 2, "offer_id": .string(offerID), "device_name": .string(deviceName),
         "device_kem_pub": .string(RelayV2Wire.base64URL(deviceAgreementPublicKey)),
         "device_sign_pub": .string(RelayV2Wire.base64URL(deviceSigningPublicKey)),
         "preview_kem_pub": .string(RelayV2Wire.base64URL(previewPublicKey)),
         "device_nonce": .string(RelayV2Wire.base64URL(deviceNonce)),
         "push_bind_token": pushBindToken.map(JSONValue.string) ?? .null,
         "hub_activation_token": hubActivationToken.map(JSONValue.string) ?? .null]
    }
    var wire: [String: JSONValue] { transcript.merging(["pair_mac": .string(RelayV2Wire.base64URL(pairMAC))]) { a, _ in a } }

    var containsEnrollmentCredentials: Bool {
        pushBindToken != nil || hubActivationToken != nil
    }

    func scrubbingEnrollmentCredentials() -> RelayV2PairInit {
        RelayV2PairInit(
            offerID: offerID,
            deviceName: deviceName,
            deviceAgreementPublicKey: deviceAgreementPublicKey,
            deviceSigningPublicKey: deviceSigningPublicKey,
            previewPublicKey: previewPublicKey,
            deviceNonce: deviceNonce,
            pushBindToken: nil,
            hubActivationToken: nil,
            pairMAC: pairMAC
        )
    }
}

struct RelayV2PairAcceptMailbox: Codable, Equatable, Sendable {
    let version: Int; let offerID: String; let deviceRoute: String
    let encapsulatedKey: Data; let ciphertext: Data; let responseHash: Data
    enum CodingKeys: String, CodingKey, CaseIterable {
        case version = "v"; case offerID = "offer_id"; case deviceRoute = "device_route"
        case encapsulatedKey = "enc"; case ciphertext = "ct"; case responseHash = "response_hash"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version); offerID = try c.decode(String.self, forKey: .offerID)
        deviceRoute = try c.decode(String.self, forKey: .deviceRoute)
        encapsulatedKey = try RelayV2Wire.decodeBase64URL(c.decode(String.self, forKey: .encapsulatedKey), exactBytes: 32)
        ciphertext = try RelayV2Wire.decodeBase64URL(c.decode(String.self, forKey: .ciphertext), minimumBytes: 16, maximumBytes: 32_768)
        responseHash = try RelayV2Wire.decodeBase64URL(c.decode(String.self, forKey: .responseHash), exactBytes: 32)
        guard version == 2, responseHash == Data(SHA256.hash(data: encapsulatedKey + ciphertext)) else {
            throw RelayV2ProtocolError.unauthenticated
        }
    }
}

enum RelayV2PairingEnrollmentKind: String, Codable, Sendable {
    case push
    case hubOnly = "hub_only"
}

/// Durable enrollment preflight. It is written before the first Push Gateway
/// or Hub activation request and owns every input that must remain identical on
/// a rescan: preview private key, installation nonce, APNs request inputs, and
/// the one-time credentials returned by enrollment.
struct RelayV2PendingPairingEnrollment: Codable, Equatable, Sendable {
    let offer: RelayV2PairingOffer
    let deviceName: String
    let kind: RelayV2PairingEnrollmentKind
    let preview: RelayV2RawKeyPair
    let installationNonce: Data
    let apnsToken: Data?
    let environment: RelayV2APNsEnvironment
    let bundleID: String
    var pushBindToken: String?
    var hubActivationToken: String?
}

/// Protected, restartable pairing transaction. It contains the exact PairInit
/// ciphertext and PairConfirm envelope so a crash can only cause an idempotent
/// byte-for-byte resend, never new cryptographic material for the same offer.
struct RelayV2PendingPairingRecord: Codable, Equatable, Sendable {
    let offer: RelayV2PairingOffer
    var identity: RelayV2Identity
    let preview: RelayV2RawKeyPair
    var pairInit: RelayV2PairInit
    let pairInitEncapsulatedKey: Data
    let pairInitCiphertext: Data
    let messageHash: Data
    var pairInitSubmitted: Bool
    var pairAcceptMailbox: RelayV2PairAcceptMailbox?
    var pairAcceptMessageID: String?
    var confirmEnvelope: RelayV2OuterEnvelope?
    /// Nil decodes old journals as the pre-accept state. True is the durable
    /// point after the Hub accepted PairConfirm and before local finalization.
    var pairConfirmAcceptedByHub: Bool? = nil
    /// Stored before PairInit credentials are scrubbed. Older journals decode
    /// nil and are upgraded from their still-complete PairInit transcript.
    var verificationCode: String? = nil
}

extension RelayV2KeychainStore {
    func savePendingPairing(_ record: RelayV2PendingPairingRecord) throws {
        try savePendingPairingData(JSONEncoder().encode(record))
    }

    func loadPendingPairing() throws -> RelayV2PendingPairingRecord? {
        guard let data = try loadPendingPairingData() else { return nil }
        return try JSONDecoder().decode(RelayV2PendingPairingRecord.self, from: data)
    }

    func savePendingPairingEnrollment(_ record: RelayV2PendingPairingEnrollment) throws {
        try savePendingPairingEnrollmentData(JSONEncoder().encode(record))
    }

    func loadPendingPairingEnrollment() throws -> RelayV2PendingPairingEnrollment? {
        guard let data = try loadPendingPairingEnrollmentData() else { return nil }
        return try JSONDecoder().decode(RelayV2PendingPairingEnrollment.self, from: data)
    }
}

protocol RelayV2PairingEnrollmentTransport: Sendable {
    func register(
        accountID: String,
        apnsToken: Data,
        environment: RelayV2APNsEnvironment,
        bundleID: String,
        previewKEMPublicKey: Data,
        installationNonce: Data,
        hubRouteID: String?,
        existingAppAttestKeyID: String?
    ) async throws -> RelayV2PushRegistrationResult

    func activateHub(
        accountID: String,
        environment: RelayV2APNsEnvironment,
        bundleID: String,
        installationNonce: Data,
        hubRouteID: String
    ) async throws -> RelayV2HubActivationResult
}

extension RelayV2PushRegistrationClient: RelayV2PairingEnrollmentTransport {}

protocol RelayV2PairingTransport: Sendable {
    func submitPairInit(offer: RelayV2PairingOffer, encapsulatedKey: Data, ciphertext: Data) async throws
    func fetchPairAccept(offer: RelayV2PairingOffer) async throws -> RelayV2PairAcceptMailbox?
    func sendPairConfirm(
        _ envelope: RelayV2OuterEnvelope,
        hubURL: URL,
        routeSigningPrivateKey: Data
    ) async throws
}

actor RelayV2HTTPPairingTransport: RelayV2PairingTransport {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30
            self.session = URLSession(
                configuration: config, delegate: RelayV2NoRedirectDelegate(), delegateQueue: nil
            )
        }
    }
    func submitPairInit(offer: RelayV2PairingOffer, encapsulatedKey: Data, ciphertext: Data) async throws {
        let body = try RelayV2Wire.canonicalJSON(["v": .number(2), "offer_id": .string(offer.offerID),
            "enc": .string(RelayV2Wire.base64URL(encapsulatedKey)), "ct": .string(RelayV2Wire.base64URL(ciphertext))] as [String: JSONValue])
        var request = URLRequest(url: offer.hubURL.appending(path: "/v2/offers/\(offer.offerRoute)/messages"))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(RelayV2Wire.base64URL(offer.offerTransportToken))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.require(response, data: data, allowed: [200, 202])
    }
    func fetchPairAccept(offer: RelayV2PairingOffer) async throws -> RelayV2PairAcceptMailbox? {
        var request = URLRequest(url: offer.hubURL.appending(path: "/v2/offers/\(offer.offerRoute)/accept"))
        request.setValue("Bearer \(RelayV2Wire.base64URL(offer.offerTransportToken))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayV2ProtocolError.transport("No pairing response") }
        if http.statusCode == 202 || http.statusCode == 204 { return nil }
        try Self.require(response, data: data, allowed: [200])
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           Set(object.keys) == ["status", "offer_id"],
           object["status"] as? String == "waiting" {
            guard object["offer_id"] as? String == offer.offerID else {
                throw RelayV2ProtocolError.unauthenticated
            }
            return nil
        }
        try RelayV2Wire.requireExactObjectKeys(data, keys: Set(RelayV2PairAcceptMailbox.CodingKeys.allCases.map(\.rawValue)))
        return try JSONDecoder().decode(RelayV2PairAcceptMailbox.self, from: data)
    }
    func sendPairConfirm(
        _ envelope: RelayV2OuterEnvelope,
        hubURL: URL,
        routeSigningPrivateKey: Data
    ) async throws {
        let configuration = try RelayV2HubConfiguration(
            baseURL: hubURL,
            routeID: envelope.header.source,
            routeSigningPrivateKey: routeSigningPrivateKey
        )
        _ = try await RelayV2HubTransport(configuration: configuration).post(envelope)
    }
    private static func require(_ response: URLResponse, data: Data, allowed: Set<Int>) throws {
        guard data.count <= 65_536, let http = response as? HTTPURLResponse, allowed.contains(http.statusCode) else {
            throw RelayV2ProtocolError.transport("Pairing Hub rejected the request")
        }
    }
}

struct RelayV2PairAccept: Sendable, Equatable {
    let secureMessage: RelayV2SecureMessage
    let deviceID: String; let relayInstanceID: String; let deviceRoute: String
    let streamID: String; let relayKeyGeneration: UInt32
    let pushBindingID: String?; let capabilities: [String]

    init(message: RelayV2SecureMessage) throws {
        let keys: Set<String> = ["device_id", "relay_instance_id", "device_route", "stream_id",
                                 "relay_key_generation", "push_binding_id", "capabilities"]
        guard message.kind == .pairAccept, Set(message.body.keys) == keys,
              let deviceID = message.body["device_id"]?.stringValue,
              let relayInstanceID = message.body["relay_instance_id"]?.stringValue,
              let deviceRoute = message.body["device_route"]?.stringValue,
              let streamID = message.body["stream_id"]?.stringValue,
              let generationValue = message.body["relay_key_generation"]?.intValue,
              generationValue > 0, generationValue <= Int(UInt32.max),
              let capabilities = message.body["capabilities"]?.arrayValue?.compactMap(\.stringValue),
              capabilities.count == message.body["capabilities"]?.arrayValue?.count,
              [deviceID, relayInstanceID, deviceRoute, streamID].allSatisfy(RelayV2Wire.isToken) else {
            throw RelayV2ProtocolError.invalidArgument(field: "pair_accept")
        }
        self.secureMessage = message; self.deviceID = deviceID; self.relayInstanceID = relayInstanceID
        self.deviceRoute = deviceRoute; self.streamID = streamID
        self.relayKeyGeneration = UInt32(generationValue)
        self.pushBindingID = message.body["push_binding_id"]?.stringValue
        self.capabilities = capabilities
    }
}

/// Crash-restartable v1→v2 activation. PairConfirm succeeds before this object
/// is called. It then journals the exact legacy push DELETE in Keychain, fences
/// legacy approval/clarify REST sends, switches transport, and retries cleanup
/// until the old registration is deleted or confirmed absent.
@MainActor
final class RelayV2MigrationCoordinator {
    typealias LegacyEndpoint = (url: URL, token: String, pathStyle: APIPathStyle)

    private let defaults: UserDefaults
    private let keyStore: RelayV2KeychainStore
    private let legacyEndpointProvider: @MainActor @Sendable () -> LegacyEndpoint?
    private let unregisterLegacyPush:
        @Sendable (RelayV2MigrationIntent) async -> PushTokenPoster.Outcome

    init(
        defaults: UserDefaults = .standard,
        keyStore: RelayV2KeychainStore = .init(),
        legacyEndpointProvider: (@MainActor @Sendable () -> LegacyEndpoint?)? = nil,
        unregisterLegacyPush: (
            @Sendable (RelayV2MigrationIntent) async -> PushTokenPoster.Outcome
        )? = nil
    ) {
        self.defaults = defaults
        self.keyStore = keyStore
        self.legacyEndpointProvider = legacyEndpointProvider ?? {
            PushRegistrar.shared.resolveEndpoint()
        }
        self.unregisterLegacyPush = unregisterLegacyPush ?? { intent in
            guard let baseURL = intent.legacyBaseURL,
                  let token = intent.legacySessionToken,
                  let apnsToken = intent.legacyAPNsToken,
                  let rawPathStyle = intent.legacyPathStyle,
                  let pathStyle = APIPathStyle(rawValue: rawPathStyle) else { return .hardFail }
            return await PushTokenPoster(
                baseURL: baseURL,
                token: token,
                pathStyle: pathStyle
            ).unregister(token: apnsToken)
        }
    }

    func activate(accountID: String) async throws {
        guard RelayV2Wire.isToken(accountID) else {
            throw RelayV2ProtocolError.invalidArgument(field: "migration_account_id")
        }
        let intent: RelayV2MigrationIntent
        if let existing = try keyStore.loadMigrationIntent() {
            guard existing.accountID == accountID else {
                throw RelayV2ProtocolError.conflict(
                    "Another secure-relay migration is still pending"
                )
            }
            intent = existing
        } else {
            let legacyAPNsToken = KeychainService.loadRegisteredAPNsDeviceToken(
                defaults: defaults
            )
            if let legacyAPNsToken {
                guard let endpoint = legacyEndpointProvider() else {
                    // Never switch first and then discover that the exact old
                    // URL/token needed for cleanup was lost.
                    throw RelayV2ProtocolError.transport(
                        "The previous push registration could not be journaled"
                    )
                }
                intent = RelayV2MigrationIntent(
                    accountID: accountID,
                    legacyBaseURL: endpoint.url,
                    legacySessionToken: endpoint.token,
                    legacyAPNsToken: legacyAPNsToken,
                    legacyPathStyle: endpoint.pathStyle.rawValue,
                    createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
                )
            } else {
                intent = RelayV2MigrationIntent(
                    accountID: accountID,
                    legacyBaseURL: nil,
                    legacySessionToken: nil,
                    legacyAPNsToken: nil,
                    legacyPathStyle: nil,
                    createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
                )
            }
            // This is the durable cutover point. No legacy metadata or routing
            // selector changes before the journal exists.
            try keyStore.saveMigrationIntent(intent)
        }

        commitCutover(intent)
        await retryPendingCleanup()
    }

    /// Called at launch as well as directly after PairConfirm. A crash after the
    /// journal write resumes the cutover before any legacy action can be sent.
    func resumePendingCutover() async {
        guard let intent = try? keyStore.loadMigrationIntent() else { return }
        commitCutover(intent)
        await retryPendingCleanup()
    }

    private func commitCutover(_ intent: RelayV2MigrationIntent) {
        // Fence action sends first. Notification callbacks recheck this value
        // immediately before invoking REST, so a pre-resolved endpoint is inert.
        defaults.set(true, forKey: DefaultsKeys.relayV2LegacyActionsDisabled)
        defaults.set(intent.accountID, forKey: DefaultsKeys.relayV2AccountID)
        defaults.set(TransportPath.relayV2.rawValue, forKey: DefaultsKeys.transportPath)
        updateV2PushHealth(accountID: intent.accountID)
    }

    private func retryPendingCleanup() async {
        guard let intent = try? keyStore.loadMigrationIntent() else { return }
        guard intent.hasLegacyPushCleanup else {
            keyStore.deleteMigrationIntent()
            return
        }
        let outcome = await unregisterLegacyPush(intent)
        switch outcome {
        case .success, .softFail:
            // Preserve the current APNs token used by v2, but erase the separate
            // legacy-registration credential once its exact row is gone.
            KeychainService.deleteRegisteredAPNsDeviceToken(defaults: defaults)
            defaults.removeObject(forKey: DefaultsKeys.pushLastDeviceTokenDigest)
            defaults.removeObject(forKey: DefaultsKeys.pushLastEvents)
            defaults.removeObject(forKey: DefaultsKeys.pushLastEnv)
            defaults.removeObject(forKey: DefaultsKeys.pushLastRegistrationScope)
            updateV2PushHealth(accountID: intent.accountID)
            keyStore.deleteMigrationIntent()
        case .validationRejected, .hardFail:
            // Neither outcome proves the old row is absent. Keep the exact
            // Keychain intent; the next launch retries with the same tuple.
            break
        }
    }

    private func updateV2PushHealth(accountID: String) {
        let state = try? keyStore.loadPushRegistrationState(accountID: accountID)
        defaults.set(
            state?.endpointID != nil && state?.attestationPhase == .committed,
            forKey: DefaultsKeys.pushRegistrationHealthy
        )
    }
}

@MainActor
final class RelayV2PairingCoordinator: ObservableObject {
    enum State: Equatable { case idle, submitting, awaitingAccept(code: String), confirming, paired(String), failed(String) }
    @Published private(set) var state: State = .idle
    private let transport: any RelayV2PairingTransport
    private let keyStore: RelayV2KeychainStore
    private let defaults: UserDefaults
    private let migrationCoordinator: RelayV2MigrationCoordinator
    private var pending: RelayV2PendingPairingRecord?
    private(set) var pendingEnrollment: RelayV2PendingPairingEnrollment?

    init(
        transport: any RelayV2PairingTransport,
        keyStore: RelayV2KeychainStore = .init(),
        defaults: UserDefaults = .standard,
        migrationCoordinator: RelayV2MigrationCoordinator? = nil
    ) {
        self.transport = transport; self.keyStore = keyStore; self.defaults = defaults
        self.migrationCoordinator = migrationCoordinator ?? RelayV2MigrationCoordinator(
            defaults: defaults,
            keyStore: keyStore
        )
        if var restored = try? keyStore.loadPendingPairing() {
            let storageID = "pairing_\(restored.offer.offerID)"
            let restoredCode = restored.verificationCode
                ?? (try? verificationCode(offer: restored.offer, pairInit: restored.pairInit))
            if restored.pairInit.containsEnrollmentCredentials
                || restored.verificationCode == nil {
                if let restoredCode {
                    var sanitized = restored
                    sanitized.pairInit = restored.pairInit.scrubbingEnrollmentCredentials()
                    sanitized.verificationCode = restoredCode
                    do {
                        try keyStore.savePendingPairing(sanitized)
                        restored = sanitized
                        try keyStore.scrubConsumedEnrollmentCredentials(
                            accountID: storageID
                        )
                        keyStore.deletePendingPairingEnrollment()
                    } catch {
                        // Keep the older complete journal recoverable and retry
                        // its upgrade on the next coordinator construction.
                    }
                }
            } else {
                try? keyStore.scrubConsumedEnrollmentCredentials(accountID: storageID)
                keyStore.deletePendingPairingEnrollment()
            }
            let now = UInt64(Date().timeIntervalSince1970 * 1_000)
            if restored.pairConfirmAcceptedByHub == true {
                // Hub acceptance is terminal remote success. Offer expiry no
                // longer authorizes rollback; only local finalization remains.
                pending = restored
                state = .confirming
                keyStore.deletePendingPairingEnrollment()
            } else if restored.offer.expiresAtMilliseconds > now {
                pending = restored
                keyStore.deletePendingPairingEnrollment()
                if restored.confirmEnvelope != nil {
                    state = .confirming
                } else if let code = restored.verificationCode ?? restoredCode {
                    state = .awaitingAccept(code: code)
                }
            } else {
                keyStore.deleteEnrollmentState(accountID: "pairing_\(restored.offer.offerID)")
                keyStore.deletePendingPairing()
                keyStore.deletePendingPairingEnrollment()
            }
        } else if let restoredEnrollment = try? keyStore.loadPendingPairingEnrollment() {
            let now = UInt64(Date().timeIntervalSince1970 * 1_000)
            if restoredEnrollment.offer.expiresAtMilliseconds > now {
                pendingEnrollment = restoredEnrollment
            } else {
                keyStore.deleteEnrollmentState(
                    accountID: "pairing_\(restoredEnrollment.offer.offerID)"
                )
                keyStore.deletePendingPairingEnrollment()
            }
        }
    }

    /// Writes every hosted-enrollment input before the first network mutation.
    /// A repeated scan of the same offer returns the existing record verbatim,
    /// even if UI defaults (name, push toggle, generated keys) have changed.
    func prepareHostedEnrollment(
        offer: RelayV2PairingOffer,
        deviceName: String,
        notificationsEnabled: Bool,
        apnsToken: Data?,
        environment: RelayV2APNsEnvironment,
        bundleID: String,
        previewKeyPair: RelayV2RawKeyPair? = nil,
        installationNonce: Data? = nil
    ) throws -> RelayV2PendingPairingEnrollment {
        guard pending == nil else {
            throw RelayV2ProtocolError.conflict("A pairing transaction is already pending")
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        if let existing = pendingEnrollment {
            if existing.offer == offer, existing.offer.expiresAtMilliseconds > now {
                return existing
            }
            if existing.offer.expiresAtMilliseconds > now {
                throw RelayV2ProtocolError.conflict(
                    "Another hosted enrollment transaction is already pending"
                )
            }
            keyStore.deleteEnrollmentState(
                accountID: "pairing_\(existing.offer.offerID)"
            )
            keyStore.deletePendingPairingEnrollment()
            pendingEnrollment = nil
        }
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: RelayV2PairingEnrollmentKind = notificationsEnabled ? .push : .hubOnly
        guard offer.expiresAtMilliseconds > now, !trimmedName.isEmpty, !bundleID.isEmpty,
              !notificationsEnabled || apnsToken?.isEmpty == false else {
            throw RelayV2ProtocolError.invalidArgument(field: "pairing_enrollment")
        }
        let preview = previewKeyPair ?? RelayV2Crypto.generateAgreementKeyPair()
        let nonce: Data
        if let installationNonce {
            nonce = installationNonce
        } else {
            nonce = try Self.randomBytes(count: 32)
        }
        guard preview.privateKey.count == 32, preview.publicKey.count == 32,
              (16...64).contains(nonce.count) else {
            throw RelayV2ProtocolError.invalidArgument(field: "pairing_enrollment")
        }
        let record = RelayV2PendingPairingEnrollment(
            offer: offer,
            deviceName: trimmedName,
            kind: kind,
            preview: preview,
            installationNonce: nonce,
            apnsToken: notificationsEnabled ? apnsToken : nil,
            environment: environment,
            bundleID: bundleID,
            pushBindToken: nil,
            hubActivationToken: nil
        )
        try keyStore.savePendingPairingEnrollment(record)
        pendingEnrollment = record
        return record
    }

    func enrollHostedAndBegin(
        offer: RelayV2PairingOffer,
        deviceName: String,
        notificationsEnabled: Bool,
        apnsToken: Data?,
        environment: RelayV2APNsEnvironment,
        bundleID: String,
        enrollmentTransport: any RelayV2PairingEnrollmentTransport
    ) async throws -> String {
        var enrollment = try prepareHostedEnrollment(
            offer: offer,
            deviceName: deviceName,
            notificationsEnabled: notificationsEnabled,
            apnsToken: apnsToken,
            environment: environment,
            bundleID: bundleID
        )
        let storageID = "pairing_\(enrollment.offer.offerID)"
        switch enrollment.kind {
        case .push:
            guard let token = enrollment.apnsToken else {
                throw RelayV2ProtocolError.invalidArgument(field: "apns_token")
            }
            let result = try await enrollmentTransport.register(
                accountID: storageID,
                apnsToken: token,
                environment: enrollment.environment,
                bundleID: enrollment.bundleID,
                previewKEMPublicKey: enrollment.preview.publicKey,
                installationNonce: enrollment.installationNonce,
                hubRouteID: enrollment.offer.relayRoute,
                existingAppAttestKeyID: nil
            )
            guard !result.bindToken.isEmpty,
                  let activation = result.hubActivationToken,
                  !activation.isEmpty else {
                throw RelayV2ProtocolError.invalidArgument(
                    field: "hosted_enrollment_response"
                )
            }
            enrollment.pushBindToken = result.bindToken
            enrollment.hubActivationToken = activation
        case .hubOnly:
            let activation = try await enrollmentTransport.activateHub(
                accountID: storageID,
                environment: enrollment.environment,
                bundleID: enrollment.bundleID,
                installationNonce: enrollment.installationNonce,
                hubRouteID: enrollment.offer.relayRoute
            )
            guard !activation.token.isEmpty else {
                throw RelayV2ProtocolError.invalidArgument(
                    field: "hosted_enrollment_response"
                )
            }
            enrollment.hubActivationToken = activation.token
        }

        // The enrollment client protects a lost response; this record protects
        // the returned credentials before PairInit construction starts.
        try keyStore.savePendingPairingEnrollment(enrollment)
        pendingEnrollment = enrollment
        let code = try await begin(
            offer: enrollment.offer,
            deviceName: enrollment.deviceName,
            pushBindToken: enrollment.pushBindToken,
            hubActivationToken: enrollment.hubActivationToken,
            previewKeyPair: enrollment.preview
        )
        // PairInit is already durable. A crash before this delete leaves two
        // harmless journals; init always prefers the later pairing record.
        keyStore.deletePendingPairingEnrollment()
        pendingEnrollment = nil
        return code
    }

    func begin(
        offer: RelayV2PairingOffer,
        deviceName: String,
        pushBindToken: String?,
        hubActivationToken: String?,
        previewKeyPair: RelayV2RawKeyPair? = nil
    ) async throws -> String {
        guard pending == nil else {
            throw RelayV2ProtocolError.conflict("A pairing transaction is already pending")
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        guard offer.expiresAtMilliseconds > now, !deviceName.isEmpty,
              hubActivationToken.map({ !$0.isEmpty }) ?? true else {
            throw RelayV2ProtocolError.expired
        }
        state = .submitting
        var identity = RelayV2Identity.makeUnpaired()
        identity.hubURL = offer.hubURL; identity.agentRouteID = offer.relayRoute
        identity.agentAgreementPublicKey = offer.relayAgreementPublicKey
        identity.agentSigningPublicKey = offer.relaySigningPublicKey
        let preview = previewKeyPair ?? RelayV2Crypto.generateAgreementKeyPair()
        guard let keys = identity.currentKeys else { throw RelayV2ProtocolError.revoked }
        var nonce = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else {
            throw RelayV2ProtocolError.transport("Secure random generation failed")
        }
        let unsigned = RelayV2PairInit(
            offerID: offer.offerID, deviceName: deviceName,
            deviceAgreementPublicKey: try keys.agreementPublicKey,
            deviceSigningPublicKey: try keys.signingPublicKey,
            previewPublicKey: preview.publicKey, deviceNonce: Data(nonce),
            pushBindToken: pushBindToken, hubActivationToken: hubActivationToken,
            pairMAC: Data(repeating: 0, count: 32)
        )
        let mac = Data(HMAC<SHA256>.authenticationCode(
            for: try RelayV2Wire.canonicalJSON(unsigned.transcript),
            using: SymmetricKey(data: offer.pairSecret)
        ))
        let pairInit = RelayV2PairInit(
            offerID: unsigned.offerID, deviceName: unsigned.deviceName,
            deviceAgreementPublicKey: unsigned.deviceAgreementPublicKey,
            deviceSigningPublicKey: unsigned.deviceSigningPublicKey,
            previewPublicKey: unsigned.previewPublicKey, deviceNonce: unsigned.deviceNonce,
            pushBindToken: unsigned.pushBindToken, hubActivationToken: unsigned.hubActivationToken,
            pairMAC: mac
        )
        let sealed = try RelayV2Crypto.sealBaseMessage(
            plaintext: RelayV2Wire.canonicalJSON(pairInit.wire),
            recipientPublicKey: offer.relayAgreementPublicKey,
            info: Data("hermes-mobile/hrp2/pair/init".utf8),
            authenticatedData: offer.authenticatedData
        )
        let hash = Data(SHA256.hash(data: sealed.encapsulatedKey + sealed.ciphertext))
        let code = try verificationCode(offer: offer, pairInit: pairInit)
        var transaction = RelayV2PendingPairingRecord(
            offer: offer,
            identity: identity,
            preview: preview,
            pairInit: pairInit.scrubbingEnrollmentCredentials(),
            pairInitEncapsulatedKey: sealed.encapsulatedKey,
            pairInitCiphertext: sealed.ciphertext, messageHash: hash,
            pairInitSubmitted: false, pairAcceptMailbox: nil,
            pairAcceptMessageID: nil,
            confirmEnvelope: nil,
            verificationCode: code
        )
        try keyStore.savePendingPairing(transaction)
        pending = transaction
        // The encrypted PairInit and verification code now contain everything
        // needed for exact resend/recovery. Remove one-time enrollment material
        // before the first PairInit network mutation.
        try keyStore.scrubConsumedEnrollmentCredentials(
            accountID: "pairing_\(offer.offerID)"
        )
        keyStore.deletePendingPairingEnrollment()
        pendingEnrollment = nil
        do {
            try await transport.submitPairInit(
                offer: offer, encapsulatedKey: sealed.encapsulatedKey, ciphertext: sealed.ciphertext
            )
            transaction.pairInitSubmitted = true
            try keyStore.savePendingPairing(transaction)
            pending = transaction
        } catch {
            // The exact prepared PairInit is already protected. Enter the normal
            // waiting state so polling can idempotently resubmit after a lost
            // response or process restart.
            state = .awaitingAccept(code: code)
            return code
        }
        state = .awaitingAccept(code: code)
        return code
    }

    func pollAndConfirm() async throws -> RelayV2Identity? {
        guard var pending else { throw RelayV2ProtocolError.conflict("No pairing is pending") }
        if pending.pairConfirmAcceptedByHub == true {
            try await complete(pending)
            return pending.identity
        }
        let currentTime = UInt64(Date().timeIntervalSince1970 * 1_000)
        guard pending.offer.expiresAtMilliseconds > currentTime else {
            keyStore.deleteIdentity(accountID: pending.identity.accountID)
            keyStore.deleteEnrollmentState(accountID: "pairing_\(pending.offer.offerID)")
            keyStore.deletePendingPairing(); self.pending = nil; state = .failed("Pairing offer expired")
            throw RelayV2ProtocolError.expired
        }
        if let confirm = pending.confirmEnvelope {
            try persistAcceptedIdentity(pending)
            guard let keys = pending.identity.currentKeys else { throw RelayV2ProtocolError.revoked }
            try await transport.sendPairConfirm(
                confirm, hubURL: pending.offer.hubURL,
                routeSigningPrivateKey: keys.signingPrivateKey
            )
            pending.pairConfirmAcceptedByHub = true
            try keyStore.savePendingPairing(pending)
            self.pending = pending
            try await complete(pending)
            return pending.identity
        }
        if !pending.pairInitSubmitted {
            try await transport.submitPairInit(
                offer: pending.offer,
                encapsulatedKey: pending.pairInitEncapsulatedKey,
                ciphertext: pending.pairInitCiphertext
            )
            pending.pairInitSubmitted = true
            try keyStore.savePendingPairing(pending)
            self.pending = pending
        }
        guard let mailbox = try await transport.fetchPairAccept(offer: pending.offer) else { return nil }
        guard mailbox.offerID == pending.offer.offerID else { throw RelayV2ProtocolError.unauthenticated }
        let aad = try RelayV2Wire.canonicalJSON([
            "v": .number(2), "offer_id": .string(pending.offer.offerID),
            "device_route": .string(mailbox.deviceRoute),
            "message_hash": .string(RelayV2Wire.base64URL(pending.messageHash)),
        ] as [String: JSONValue])
        guard let keys = pending.identity.currentKeys else { throw RelayV2ProtocolError.revoked }
        let plaintext = try RelayV2Crypto.openAuthenticatedMessage(
            encapsulatedKey: mailbox.encapsulatedKey, ciphertext: mailbox.ciphertext,
            recipientPrivateKey: keys.agreementPrivateKey,
            senderPublicKey: pending.offer.relayAgreementPublicKey,
            info: RelayV2Wire.hpkeInfo(.control, .agentToDevice), authenticatedData: aad
        )
        let accept = try RelayV2PairAccept(message: RelayV2SecureMessage.decodeStrict(from: plaintext))
        guard accept.deviceRoute == mailbox.deviceRoute,
              accept.secureMessage.senderKeyGeneration == accept.relayKeyGeneration,
              accept.secureMessage.expiresAtMilliseconds == pending.offer.expiresAtMilliseconds else {
            throw RelayV2ProtocolError.unauthenticated
        }
        pending.identity.deviceID = accept.deviceID; pending.identity.routeID = accept.deviceRoute
        pending.identity.streamID = accept.streamID; pending.identity.relayInstanceID = accept.relayInstanceID
        pending.identity.agentKeyGeneration = accept.relayKeyGeneration
        state = .confirming
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let expiry = min(pending.offer.expiresAtMilliseconds, now + 300_000)
        let mid = RelayV2Wire.randomMessageID()
        let message = try RelayV2SecureMessage(
            messageID: mid, kind: .pairConfirm, senderKeyGeneration: keys.generation,
            createdAtMilliseconds: now, expiresAtMilliseconds: expiry,
            body: ["offer_id": .string(pending.offer.offerID), "device_id": .string(accept.deviceID),
                   "response_hash": .string(RelayV2Wire.base64URL(mailbox.responseHash)),
                   "pair_accept_mid": .string(accept.secureMessage.messageID)]
        )
        let header = try RelayV2OuterHeader(source: accept.deviceRoute, destination: pending.offer.relayRoute,
            messageID: mid, messageClass: .control, expiresAtMilliseconds: expiry,
            recipientKeyGeneration: accept.relayKeyGeneration)
        let envelope = try RelayV2Crypto.sealAuthenticatedEnvelope(
            header: header, message: message, recipientPublicKey: pending.offer.relayAgreementPublicKey,
            senderAgreementPrivateKey: keys.agreementPrivateKey, senderSigningPrivateKey: keys.signingPrivateKey,
            purpose: .control, direction: .deviceToAgent)
        pending.pairAcceptMailbox = mailbox
        pending.pairAcceptMessageID = accept.secureMessage.messageID
        pending.confirmEnvelope = envelope
        try keyStore.savePendingPairing(pending)
        self.pending = pending
        try persistAcceptedIdentity(pending)
        try await transport.sendPairConfirm(
            envelope, hubURL: pending.offer.hubURL,
            routeSigningPrivateKey: keys.signingPrivateKey
        )
        pending.pairConfirmAcceptedByHub = true
        try keyStore.savePendingPairing(pending)
        self.pending = pending
        try await complete(pending)
        return pending.identity
    }

    private func complete(_ pending: RelayV2PendingPairingRecord) async throws {
        try keyStore.migrateEnrollmentState(
            from: "pairing_\(pending.offer.offerID)",
            to: pending.identity.accountID
        )
        try keyStore.scrubConsumedEnrollmentCredentials(
            accountID: pending.identity.accountID
        )
        try await migrationCoordinator.activate(accountID: pending.identity.accountID)
        keyStore.deletePendingPairingEnrollment()
        keyStore.deletePendingPairing()
        self.pending = nil; pendingEnrollment = nil; state = .paired(pending.identity.accountID)
    }

    private func persistAcceptedIdentity(_ pending: RelayV2PendingPairingRecord) throws {
        try keyStore.saveIdentity(pending.identity)
        try keyStore.savePreviewKey(.init(
            accountID: pending.identity.accountID,
            privateKey: pending.preview.privateKey,
            agentAgreementPublicKey: pending.offer.relayAgreementPublicKey,
            generation: 1
        ))
    }

    func cancel() {
        if pending?.pairConfirmAcceptedByHub == true {
            // Remote activation already committed. Dismissal may pause UI work,
            // but cannot turn accepted completion back into a cancellable offer.
            state = .confirming
            return
        }
        if let pending {
            keyStore.deleteIdentity(accountID: pending.identity.accountID)
            keyStore.deleteEnrollmentState(accountID: "pairing_\(pending.offer.offerID)")
        }
        if let pendingEnrollment {
            keyStore.deleteEnrollmentState(
                accountID: "pairing_\(pendingEnrollment.offer.offerID)"
            )
        }
        keyStore.deletePendingPairingEnrollment()
        keyStore.deletePendingPairing()
        pending = nil
        pendingEnrollment = nil
        state = .idle
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw RelayV2ProtocolError.transport("Secure random generation failed")
        }
        return Data(bytes)
    }

    private func verificationCode(offer: RelayV2PairingOffer, pairInit: RelayV2PairInit) throws -> String {
        let offerTranscript: [String: JSONValue] = ["v": 2, "offer_id": .string(offer.offerID),
            "offer_route": .string(offer.offerRoute), "relay_route": .string(offer.relayRoute),
            "expires_at_ms": .number(Double(offer.expiresAtMilliseconds)),
            "relay_kem_pub": .string(RelayV2Wire.base64URL(offer.relayAgreementPublicKey)),
            "relay_sign_pub": .string(RelayV2Wire.base64URL(offer.relaySigningPublicKey))]
        let verification: [String: JSONValue] = [
            "offer": .object(offerTranscript), "pair_init": .object(pairInit.transcript),
        ]
        let canonical = try RelayV2Wire.canonicalJSON(verification)
        let bytes = Data("hermes-mobile/hrp2/pair/verification-code\0".utf8) + canonical
        let digest = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: offer.pairSecret)))
        let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let value = String(format: "%06d", number); return "\(value.prefix(3)) \(value.suffix(3))"
    }
}

extension DefaultsKeys {
    static let relayV2AccountID = "hermes.relayV2.accountID"
    static func relayV2AccountIDValue(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: relayV2AccountID) ?? ""
    }
}
