import CryptoKit
import DeviceCheck
import Foundation

struct RelayV2PushRegistrationResult: Codable, Equatable, Sendable {
    let endpointID: String
    let bindToken: String
    let bindTokenExpiresAtMilliseconds: UInt64
    let hubActivationToken: String?
    let hubActivationTokenExpiresAtMilliseconds: UInt64?
    let appAttestKeyID: String

    enum CodingKeys: String, CodingKey {
        case endpointID = "endpoint_id"
        case bindToken = "bind_token"
        case bindTokenExpiresAtMilliseconds = "bind_token_expires_at_ms"
        case hubActivationToken = "hub_activation_token"
        case hubActivationTokenExpiresAtMilliseconds = "hub_activation_token_expires_at_ms"
        case appAttestKeyID = "app_attest_key_id"
    }

    private enum ResponseKeys: String, CodingKey {
        case endpointID = "endpoint_id"
        case bindToken = "bind_token"
        case bindTokenExpiresAtMilliseconds = "bind_token_expires_at_ms"
        case hubActivationToken = "hub_activation_token"
        case hubActivationTokenExpiresAtMilliseconds = "hub_activation_token_expires_at_ms"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpointID = try values.decode(String.self, forKey: .endpointID)
        bindToken = try values.decode(String.self, forKey: .bindToken)
        bindTokenExpiresAtMilliseconds = try values.decode(UInt64.self, forKey: .bindTokenExpiresAtMilliseconds)
        hubActivationToken = try values.decodeIfPresent(String.self, forKey: .hubActivationToken)
        hubActivationTokenExpiresAtMilliseconds = try values.decodeIfPresent(
            UInt64.self, forKey: .hubActivationTokenExpiresAtMilliseconds
        )
        appAttestKeyID = try values.decode(String.self, forKey: .appAttestKeyID)
        guard bindTokenExpiresAtMilliseconds <= RelayV2.maximumJSONInteger,
              hubActivationTokenExpiresAtMilliseconds.map({
                  $0 <= RelayV2.maximumJSONInteger
              }) ?? true else {
            throw RelayV2ProtocolError.invalidArgument(field: "push_registration_expiry")
        }
    }

    fileprivate init(responseData: Data, appAttestKeyID: String) throws {
        struct Response: Decodable {
            let endpointID: String
            let bindToken: String
            let bindTokenExpiresAtMilliseconds: UInt64
            let hubActivationToken: String?
            let hubActivationTokenExpiresAtMilliseconds: UInt64?

            enum CodingKeys: String, CodingKey {
                case endpointID = "endpoint_id"
                case bindToken = "bind_token"
                case bindTokenExpiresAtMilliseconds = "bind_token_expires_at_ms"
                case hubActivationToken = "hub_activation_token"
                case hubActivationTokenExpiresAtMilliseconds = "hub_activation_token_expires_at_ms"
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw RelayV2ProtocolError.invalidArgument(field: "push_registration_response")
        }
        let required: Set<String> = ["endpoint_id", "bind_token", "bind_token_expires_at_ms"]
        let activation: Set<String> = ["hub_activation_token", "hub_activation_token_expires_at_ms"]
        guard Set(object.keys) == required || Set(object.keys) == required.union(activation) else {
            throw RelayV2ProtocolError.invalidArgument(field: "push_registration_response")
        }
        let response = try JSONDecoder().decode(Response.self, from: responseData)
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        guard response.endpointID.hasPrefix("ep_"),
              (try? RelayV2Wire.decodeBase64URL(response.bindToken, exactBytes: 32)) != nil,
              response.bindTokenExpiresAtMilliseconds > now,
              response.bindTokenExpiresAtMilliseconds <= RelayV2.maximumJSONInteger,
              (response.hubActivationToken == nil)
                == (response.hubActivationTokenExpiresAtMilliseconds == nil),
              response.hubActivationTokenExpiresAtMilliseconds.map({
                  $0 > now && $0 <= RelayV2.maximumJSONInteger
              }) ?? true else {
            throw RelayV2ProtocolError.invalidArgument(field: "push_registration_response")
        }
        self.endpointID = response.endpointID
        self.bindToken = response.bindToken
        self.bindTokenExpiresAtMilliseconds = response.bindTokenExpiresAtMilliseconds
        self.hubActivationToken = response.hubActivationToken
        self.hubActivationTokenExpiresAtMilliseconds = response.hubActivationTokenExpiresAtMilliseconds
        self.appAttestKeyID = appAttestKeyID
    }
}

struct RelayV2HubActivationResult: Equatable, Sendable {
    let token: String
    let expiresAtMilliseconds: UInt64

    fileprivate init(responseData: Data) throws {
        struct Response: Decodable {
            let token: String
            let expiresAtMilliseconds: UInt64
            enum CodingKeys: String, CodingKey {
                case token = "hub_activation_token"
                case expiresAtMilliseconds = "hub_activation_token_expires_at_ms"
            }
        }
        try RelayV2Wire.requireExactObjectKeys(
            responseData,
            keys: ["hub_activation_token", "hub_activation_token_expires_at_ms"]
        )
        let response = try JSONDecoder().decode(Response.self, from: responseData)
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        guard !response.token.isEmpty, response.expiresAtMilliseconds > now,
              response.expiresAtMilliseconds <= RelayV2.maximumJSONInteger else {
            throw RelayV2ProtocolError.invalidArgument(field: "hub_activation_response")
        }
        token = response.token
        expiresAtMilliseconds = response.expiresAtMilliseconds
    }
}

protocol RelayV2AppAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

struct RelayV2LiveAppAttest: RelayV2AppAttesting {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

/// Registers the APNs endpoint with the separate Push Gateway. Unsupported App
/// Attest is an explicit failure: production never falls back to open endpoint
/// enrollment, a bearer gateway token, or the Relay Hub credential.
actor RelayV2PushRegistrationClient {
    private enum RegistrationFailure: Error {
        case initialAttestationRequired
    }
    private struct Challenge: Decodable {
        let challenge: String
        let expiresAtMilliseconds: UInt64

        enum CodingKeys: String, CodingKey {
            case challenge
            case expiresAtMilliseconds = "expires_at_ms"
        }
    }

    private struct RequestBody: Encodable {
        let challenge: String
        let appAttestKeyID: String
        let assertion: String
        let attestation: String?
        let apnsToken: String
        let environment: RelayV2APNsEnvironment
        let bundleID: String
        let previewKEMPublicKey: String
        let installationNonce: String
        let hubRouteID: String?

        enum CodingKeys: String, CodingKey {
            case challenge
            case appAttestKeyID = "app_attest_key_id"
            case assertion
            case attestation
            case apnsToken = "apns_token"
            case environment
            case bundleID = "bundle_id"
            case previewKEMPublicKey = "preview_kem_pub"
            case installationNonce = "installation_nonce"
            case hubRouteID = "hub_route_id"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(challenge, forKey: .challenge)
            try container.encode(appAttestKeyID, forKey: .appAttestKeyID)
            try container.encode(assertion, forKey: .assertion)
            if let attestation { try container.encode(attestation, forKey: .attestation) }
            else { try container.encodeNil(forKey: .attestation) }
            try container.encode(apnsToken, forKey: .apnsToken)
            try container.encode(environment, forKey: .environment)
            try container.encode(bundleID, forKey: .bundleID)
            try container.encode(previewKEMPublicKey, forKey: .previewKEMPublicKey)
            try container.encode(installationNonce, forKey: .installationNonce)
            try container.encodeIfPresent(hubRouteID, forKey: .hubRouteID)
        }
    }

    private struct ActivationBody: Encodable {
        let challenge: String
        let appAttestKeyID: String
        let assertion: String
        let attestation: String?
        let bundleID: String
        let environment: RelayV2APNsEnvironment
        let installationNonce: String
        let hubRouteID: String

        enum CodingKeys: String, CodingKey {
            case challenge, assertion, attestation, environment
            case appAttestKeyID = "app_attest_key_id"
            case bundleID = "bundle_id"
            case installationNonce = "installation_nonce"
            case hubRouteID = "hub_route_id"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(challenge, forKey: .challenge)
            try container.encode(appAttestKeyID, forKey: .appAttestKeyID)
            try container.encode(assertion, forKey: .assertion)
            if let attestation { try container.encode(attestation, forKey: .attestation) }
            else { try container.encodeNil(forKey: .attestation) }
            try container.encode(bundleID, forKey: .bundleID)
            try container.encode(environment, forKey: .environment)
            try container.encode(installationNonce, forKey: .installationNonce)
            try container.encode(hubRouteID, forKey: .hubRouteID)
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let appAttest: any RelayV2AppAttesting
    private let keyStore: RelayV2KeychainStore

    init(
        baseURL: URL,
        session: URLSession? = nil,
        appAttest: any RelayV2AppAttesting = RelayV2LiveAppAttest(),
        keyStore: RelayV2KeychainStore = .init()
    ) throws {
        guard Self.isTrusted(baseURL) else {
            throw RelayV2ProtocolError.invalidArgument(field: "push_gateway_url")
        }
        self.baseURL = baseURL
        self.appAttest = appAttest
        self.keyStore = keyStore
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(
                configuration: configuration,
                delegate: RelayV2NoRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    func register(
        accountID: String,
        apnsToken: Data,
        environment: RelayV2APNsEnvironment,
        bundleID: String,
        previewKEMPublicKey: Data,
        installationNonce: Data,
        hubRouteID: String? = nil,
        existingAppAttestKeyID: String? = nil
    ) async throws -> RelayV2PushRegistrationResult {
        guard appAttest.isSupported else {
            throw RelayV2ProtocolError.transport("App Attest is unavailable on this device")
        }
        guard !apnsToken.isEmpty, previewKEMPublicKey.count == 32,
              (16...64).contains(installationNonce.count), !bundleID.isEmpty else {
            throw RelayV2ProtocolError.invalidArgument(field: "push_registration")
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        var saved = try keyStore.loadPushRegistrationState(accountID: accountID)
        if let saved {
            guard saved.installationNonce == installationNonce,
                  saved.previewPublicKey == previewKEMPublicKey,
                  saved.environment == environment else {
                throw RelayV2ProtocolError.conflict(
                    "Enrollment inputs changed for a pending registration"
                )
            }
            if let committed = saved.committedResponseData {
                return try RelayV2PushRegistrationResult(
                    responseData: committed,
                    appAttestKeyID: saved.appAttestKeyID
                )
            }
        }
        var requiresFreshAttestedKey = false
        var recoveringExpiredRequest = false
        if var pending = saved, pending.endpointID == nil {
            if let pendingBody = pending.pendingRequestBody,
               let pendingExpiry = pending.pendingRequestExpiresAtMilliseconds,
               pendingExpiry > now {
                let data = try await postData(path: "/v2/endpoints/register", body: pendingBody)
                let result = try RelayV2PushRegistrationResult(
                    responseData: data, appAttestKeyID: pending.appAttestKeyID
                )
                pending.endpointID = result.endpointID
                pending.pendingAttestation = nil
                pending.pendingRequestBody = nil
                pending.pendingRequestExpiresAtMilliseconds = nil
                pending.attestationPhase = .committed
                pending.committedResponseData = data
                try keyStore.savePushRegistrationState(pending)
                return result
            }
            // A partial or expired request cannot be combined with a fresh
            // challenge. App Attest attestations are single-use per key, so
            // discard that key and create a new attested key below.
            if pending.pendingRequestBody != nil,
               pending.attestationPhase == .requestReady
                || pending.attestationPhase == .recoveryRequestReady {
                // The server may have committed the lost response. Prove that
                // first with a fresh assertion from the original key and a null
                // attestation; only its typed initial-required response permits
                // replacing the installation key.
                recoveringExpiredRequest = true
                pending.pendingAttestation = nil
                pending.pendingRequestBody = nil
                pending.pendingRequestExpiresAtMilliseconds = nil
                pending.attestationPhase = .recoveryStarted
                saved = pending
                try keyStore.savePushRegistrationState(pending)
            } else if pending.pendingAttestation != nil
                || pending.attestationPhase == .attestationStarted
                || pending.attestationPhase == .attestationReturned {
                requiresFreshAttestedKey = true
                pending.pendingAttestation = nil
                pending.pendingRequestBody = nil
                pending.pendingRequestExpiresAtMilliseconds = nil
                pending.attestationPhase = .keyGenerated
                saved = pending
                try keyStore.savePushRegistrationState(pending)
            }
        }
        if saved?.endpointID == nil, saved?.attestationPhase == .recoveryStarted {
            recoveringExpiredRequest = true
        }
        let challenge = try await fetchChallenge()
        guard challenge.expiresAtMilliseconds > now else { throw RelayV2ProtocolError.expired }

        let token = apnsToken.map { String(format: "%02x", $0) }.joined()
        let preview = RelayV2Wire.base64URL(previewKEMPublicKey)
        let nonce = RelayV2Wire.base64URL(installationNonce)
        let transcript = Self.registrationTranscript(
            challenge: challenge.challenge,
            apnsToken: token,
            bundleID: bundleID,
            environment: environment.rawValue,
            previewKEMPublicKey: preview,
            installationNonce: nonce,
            operation: "endpoint-register",
            hubRouteID: hubRouteID
        )
        let digest = Data(SHA256.hash(data: transcript))
        let keyID: String
        if requiresFreshAttestedKey {
            keyID = try await appAttest.generateKey()
            saved = RelayV2PushRegistrationState(
                accountID: accountID, endpointID: nil, appAttestKeyID: keyID,
                pendingAttestation: nil, pendingRequestBody: nil,
                pendingRequestExpiresAtMilliseconds: nil,
                installationNonce: installationNonce,
                previewPublicKey: previewKEMPublicKey, environment: environment
            )
            try keyStore.savePushRegistrationState(saved!)
        } else if let saved {
            keyID = saved.appAttestKeyID
        } else if let existingAppAttestKeyID {
            keyID = existingAppAttestKeyID
        } else {
            keyID = try await appAttest.generateKey()
        }
        let attestation: Data?
        if recoveringExpiredRequest {
            attestation = nil
        } else if saved?.endpointID == nil {
            if saved == nil {
                saved = RelayV2PushRegistrationState(
                    accountID: accountID, endpointID: nil, appAttestKeyID: keyID,
                    pendingAttestation: nil, pendingRequestBody: nil,
                    pendingRequestExpiresAtMilliseconds: nil,
                    installationNonce: installationNonce,
                    previewPublicKey: previewKEMPublicKey, environment: environment
                )
                try keyStore.savePushRegistrationState(saved!)
            }
            // Persist the call boundary before invoking App Attest. If the
            // process dies after Apple consumes the key but before our return is
            // persisted, restart generates a fresh key instead of attempting to
            // attest the potentially already-attested key again.
            saved?.attestationPhase = .attestationStarted
            try keyStore.savePushRegistrationState(saved!)
            let generated = try await appAttest.attestKey(keyID, clientDataHash: digest)
            attestation = generated
            saved = RelayV2PushRegistrationState(
                accountID: accountID, endpointID: nil, appAttestKeyID: keyID,
                pendingAttestation: generated, pendingRequestBody: nil,
                pendingRequestExpiresAtMilliseconds: nil,
                installationNonce: installationNonce,
                previewPublicKey: previewKEMPublicKey, environment: environment
            )
            saved?.attestationPhase = .attestationReturned
            try keyStore.savePushRegistrationState(saved!)
        } else {
            attestation = nil
        }
        let assertion = try await appAttest.generateAssertion(keyID, clientDataHash: digest)
        let body = RequestBody(
            challenge: challenge.challenge,
            appAttestKeyID: keyID,
            assertion: assertion.base64EncodedString(),
            attestation: attestation?.base64EncodedString(),
            apnsToken: token,
            environment: environment,
            bundleID: bundleID,
            previewKEMPublicKey: preview,
            installationNonce: nonce,
            hubRouteID: hubRouteID
        )
        let encodedBody = try JSONEncoder().encode(body)
        if var pending = saved {
            pending.pendingRequestBody = encodedBody
            pending.pendingRequestExpiresAtMilliseconds = challenge.expiresAtMilliseconds
            pending.attestationPhase = recoveringExpiredRequest ? .recoveryRequestReady : .requestReady
            try keyStore.savePushRegistrationState(pending)
        }
        let data: Data
        do {
            data = try await postData(path: "/v2/endpoints/register", body: encodedBody)
        } catch RegistrationFailure.initialAttestationRequired where recoveringExpiredRequest {
            let freshKey = try await appAttest.generateKey()
            try keyStore.savePushRegistrationState(RelayV2PushRegistrationState(
                accountID: accountID, endpointID: nil, appAttestKeyID: freshKey,
                pendingAttestation: nil, pendingRequestBody: nil,
                pendingRequestExpiresAtMilliseconds: nil,
                installationNonce: installationNonce,
                previewPublicKey: previewKEMPublicKey, environment: environment
            ))
            return try await register(
                accountID: accountID, apnsToken: apnsToken, environment: environment,
                bundleID: bundleID, previewKEMPublicKey: previewKEMPublicKey,
                installationNonce: installationNonce, hubRouteID: hubRouteID
            )
        }
        let result = try RelayV2PushRegistrationResult(responseData: data, appAttestKeyID: keyID)
        let committed = RelayV2PushRegistrationState(
            accountID: accountID, endpointID: result.endpointID, appAttestKeyID: keyID,
            pendingAttestation: nil, pendingRequestBody: nil,
            pendingRequestExpiresAtMilliseconds: nil, installationNonce: installationNonce,
            previewPublicKey: previewKEMPublicKey, environment: environment
        )
        var finalState = committed
        finalState.attestationPhase = .committed
        finalState.committedResponseData = data
        try keyStore.savePushRegistrationState(finalState)
        return result
    }

    func activateHub(
        accountID: String,
        environment: RelayV2APNsEnvironment,
        bundleID: String,
        installationNonce: Data,
        hubRouteID: String
    ) async throws -> RelayV2HubActivationResult {
        guard appAttest.isSupported else {
            throw RelayV2ProtocolError.transport("App Attest is unavailable on this device")
        }
        guard RelayV2Wire.isToken(accountID), RelayV2Wire.isToken(hubRouteID),
              !bundleID.isEmpty, (16...64).contains(installationNonce.count) else {
            throw RelayV2ProtocolError.invalidArgument(field: "hub_activation")
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        var saved = try keyStore.loadHubActivationState(accountID: accountID)
        if let saved {
            guard saved.installationNonce == installationNonce,
                  saved.environment == environment else {
                throw RelayV2ProtocolError.conflict(
                    "Enrollment inputs changed for a pending Hub activation"
                )
            }
            if let committed = saved.committedResponseData {
                return try RelayV2HubActivationResult(responseData: committed)
            }
        }
        var needsFreshKey = false
        var recoveringExpiredRequest = false
        if var pending = saved {
            if let body = pending.pendingRequestBody,
               let expiry = pending.pendingRequestExpiresAtMilliseconds,
               expiry > now {
                let response = try await postData(path: "/v2/hub-activations", body: body)
                let result = try RelayV2HubActivationResult(responseData: response)
                pending.isAttested = true
                pending.pendingAttestation = nil
                pending.pendingRequestBody = nil
                pending.pendingRequestExpiresAtMilliseconds = nil
                pending.attestationPhase = .committed
                pending.committedResponseData = response
                try keyStore.saveHubActivationState(pending)
                return result
            }
            if pending.pendingRequestBody != nil,
               pending.attestationPhase == .requestReady
                || pending.attestationPhase == .recoveryRequestReady {
                recoveringExpiredRequest = true
                pending.pendingAttestation = nil
                pending.pendingRequestBody = nil
                pending.pendingRequestExpiresAtMilliseconds = nil
                pending.attestationPhase = .recoveryStarted
                saved = pending
                try keyStore.saveHubActivationState(pending)
            } else if pending.pendingAttestation != nil
                || pending.attestationPhase == .attestationStarted
                || pending.attestationPhase == .attestationReturned {
                needsFreshKey = true
                pending.pendingAttestation = nil
                pending.pendingRequestBody = nil
                pending.pendingRequestExpiresAtMilliseconds = nil
                pending.attestationPhase = .keyGenerated
                saved = pending
                try keyStore.saveHubActivationState(pending)
            }
        }
        if saved?.attestationPhase == .recoveryStarted {
            recoveringExpiredRequest = true
        }

        let challenge = try await fetchChallenge()
        guard challenge.expiresAtMilliseconds > now else { throw RelayV2ProtocolError.expired }
        let nonce = RelayV2Wire.base64URL(installationNonce)
        let transcript = RelayV2Wire.lengthPrefixed(
            domain: Data("HPG2ACTIVATE".utf8),
            fields: [
                Data(challenge.challenge.utf8), Data(bundleID.utf8),
                Data(environment.rawValue.utf8), Data(nonce.utf8),
                Data("hub-activate".utf8), Data(hubRouteID.utf8),
            ]
        )
        let digest = Data(SHA256.hash(data: transcript))
        let keyID: String
        if needsFreshKey || saved == nil {
            keyID = try await appAttest.generateKey()
            saved = RelayV2HubActivationState(
                accountID: accountID, appAttestKeyID: keyID, isAttested: false,
                pendingAttestation: nil, pendingRequestBody: nil,
                pendingRequestExpiresAtMilliseconds: nil,
                installationNonce: installationNonce, environment: environment
            )
            try keyStore.saveHubActivationState(saved!)
        } else {
            keyID = saved!.appAttestKeyID
        }
        let attestation: Data?
        if recoveringExpiredRequest || saved?.isAttested == true {
            attestation = nil
        } else {
            saved?.attestationPhase = .attestationStarted
            try keyStore.saveHubActivationState(saved!)
            let generated = try await appAttest.attestKey(keyID, clientDataHash: digest)
            attestation = generated
            saved?.pendingAttestation = generated
            saved?.attestationPhase = .attestationReturned
            try keyStore.saveHubActivationState(saved!)
        }
        let assertion = try await appAttest.generateAssertion(keyID, clientDataHash: digest)
        let body = try JSONEncoder().encode(ActivationBody(
            challenge: challenge.challenge,
            appAttestKeyID: keyID,
            assertion: assertion.base64EncodedString(),
            attestation: attestation?.base64EncodedString(),
            bundleID: bundleID,
            environment: environment,
            installationNonce: nonce,
            hubRouteID: hubRouteID
        ))
        saved?.pendingRequestBody = body
        saved?.pendingRequestExpiresAtMilliseconds = challenge.expiresAtMilliseconds
        saved?.attestationPhase = recoveringExpiredRequest ? .recoveryRequestReady : .requestReady
        try keyStore.saveHubActivationState(saved!)
        let response: Data
        do {
            response = try await postData(path: "/v2/hub-activations", body: body)
        } catch RegistrationFailure.initialAttestationRequired where recoveringExpiredRequest {
            let freshKey = try await appAttest.generateKey()
            try keyStore.saveHubActivationState(RelayV2HubActivationState(
                accountID: accountID, appAttestKeyID: freshKey, isAttested: false,
                pendingAttestation: nil, pendingRequestBody: nil,
                pendingRequestExpiresAtMilliseconds: nil,
                installationNonce: installationNonce, environment: environment
            ))
            return try await activateHub(
                accountID: accountID, environment: environment, bundleID: bundleID,
                installationNonce: installationNonce, hubRouteID: hubRouteID
            )
        }
        let result = try RelayV2HubActivationResult(responseData: response)
        saved?.isAttested = true
        saved?.pendingAttestation = nil
        saved?.pendingRequestBody = nil
        saved?.pendingRequestExpiresAtMilliseconds = nil
        saved?.attestationPhase = .committed
        saved?.committedResponseData = response
        try keyStore.saveHubActivationState(saved!)
        return result
    }

    static func registrationTranscript(
        challenge: String,
        apnsToken: String,
        bundleID: String,
        environment: String,
        previewKEMPublicKey: String,
        installationNonce: String,
        operation: String,
        hubRouteID: String?
    ) -> Data {
        RelayV2Wire.lengthPrefixed(
            domain: Data("HPG2ATTEST".utf8),
            fields: [
                Data(challenge.utf8),
                Data(SHA256.hash(data: Data(apnsToken.utf8))),
                Data(bundleID.utf8),
                Data(environment.utf8),
                Data(previewKEMPublicKey.utf8),
                Data(installationNonce.utf8),
                Data(operation.utf8),
                Data((hubRouteID ?? "").utf8),
            ]
        )
    }

    func refreshToken(
        accountID: String,
        apnsToken: Data,
        bundleID: String
    ) async throws {
        guard let state = try keyStore.loadPushRegistrationState(accountID: accountID),
              let endpointID = state.endpointID else {
            throw RelayV2ProtocolError.conflict("Push endpoint is not registered")
        }
        let challenge = try await fetchChallenge()
        let token = apnsToken.map { String(format: "%02x", $0) }.joined()
        let preview = RelayV2Wire.base64URL(state.previewPublicKey)
        let nonce = RelayV2Wire.base64URL(state.installationNonce)
        let transcript = Self.registrationTranscript(
            challenge: challenge.challenge, apnsToken: token, bundleID: bundleID,
            environment: state.environment.rawValue, previewKEMPublicKey: preview,
            installationNonce: nonce, operation: "token-refresh", hubRouteID: nil
        )
        let assertion = try await appAttest.generateAssertion(
            state.appAttestKeyID, clientDataHash: Data(SHA256.hash(data: transcript))
        )
        let body: [String: JSONValue] = [
            "endpoint_id": .string(endpointID), "challenge": .string(challenge.challenge),
            "app_attest_key_id": .string(state.appAttestKeyID),
            "assertion": .string(assertion.base64EncodedString()), "apns_token": .string(token),
            "environment": .string(state.environment.rawValue), "bundle_id": .string(bundleID),
            "preview_kem_pub": .string(preview), "installation_nonce": .string(nonce),
        ]
        let data = try await post(path: "/v2/endpoints/token-refresh", body: body)
        try RelayV2Wire.requireExactObjectKeys(data, keys: ["endpoint_id", "refreshed"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["endpoint_id"] as? String == endpointID,
              root["refreshed"] as? Bool == true else {
            throw RelayV2ProtocolError.unauthenticated
        }
    }

    private func fetchChallenge() async throws -> Challenge {
        let request = URLRequest(url: try endpoint(path: "/v2/attest/challenge"))
        let (data, response) = try await session.data(for: request)
        try requireSuccess(response, data: data)
        try RelayV2Wire.requireExactObjectKeys(data, keys: ["challenge", "expires_at_ms"])
        let challenge = try JSONDecoder().decode(Challenge.self, from: data)
        guard (try? RelayV2Wire.decodeBase64URL(challenge.challenge, exactBytes: 32)) != nil,
              challenge.expiresAtMilliseconds > UInt64(Date().timeIntervalSince1970 * 1_000),
              challenge.expiresAtMilliseconds <= RelayV2.maximumJSONInteger else {
            throw RelayV2ProtocolError.invalidArgument(field: "attest_challenge")
        }
        return challenge
    }

    private func post<T: Encodable>(path: String, body: T) async throws -> Data {
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try requireSuccess(response, data: data)
        return data
    }

    private func postData(path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try requireSuccess(response, data: data)
        return data
    }

    private func endpoint(path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RelayV2ProtocolError.invalidArgument(field: "push_gateway_url")
        }
        components.path = path
        components.query = nil
        guard let url = components.url else {
            throw RelayV2ProtocolError.invalidArgument(field: "push_gateway_url")
        }
        return url
    }

    private func requireSuccess(_ response: URLResponse, data: Data) throws {
        guard data.count <= 65_536 else {
            throw RelayV2ProtocolError.transport("Push Gateway response exceeded the size limit")
        }
        guard let http = response as? HTTPURLResponse else {
            throw RelayV2ProtocolError.transport("Push Gateway returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["code"] as? String
            if http.statusCode == 409, code == "app_attest_initial_required" {
                throw RegistrationFailure.initialAttestationRequired
            }
            if http.statusCode == 409, code == "installation_key_mismatch" {
                throw RelayV2ProtocolError.unauthenticated
            }
            throw RelayV2ProtocolError.transport(
                "Push Gateway rejected endpoint registration (\(code ?? "HTTP_\(http.statusCode)"))"
            )
        }
    }

    private static func isTrusted(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return false
        }
        if scheme == "https" { return true }
        #if DEBUG
        if scheme == "http", host == "localhost" || host == "::1" || host.hasPrefix("127.") {
            return true
        }
        #endif
        return false
    }
}
