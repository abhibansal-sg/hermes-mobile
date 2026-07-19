import CryptoKit
import Foundation
import Security

struct RelayV2KeyGeneration: Codable, Equatable, Sendable {
    let generation: UInt32
    let agreementPrivateKey: Data
    let signingPrivateKey: Data
    let createdAtMilliseconds: UInt64
    var notAfterMilliseconds: UInt64? = nil

    var agreementPublicKey: Data {
        get throws { try RelayV2Crypto.agreementPublicKey(from: agreementPrivateKey) }
    }

    var signingPublicKey: Data {
        get throws { try RelayV2Crypto.signingPublicKey(from: signingPrivateKey) }
    }
}

struct RelayV2LocalPreviewKey: Codable, Equatable, Sendable {
    let generation: UInt32
    let privateKey: Data
    var notAfterMilliseconds: UInt64?
}

/// A remote Agent KEM generation retained during authenticated key rollover.
/// `notAfterMilliseconds == nil` identifies the current generation; previous
/// generations are accepted only through their signed overlap deadline.
struct RelayV2RemoteAgreementKey: Codable, Equatable, Sendable {
    let generation: UInt32
    let publicKey: Data
    var notAfterMilliseconds: UInt64?
}

struct RelayV2Identity: Codable, Equatable, Sendable {
    let accountID: String
    var deviceID: String
    var hubURL: URL?
    var streamID: String?
    var relayInstanceID: String?
    var routeID: String?
    var grantID: String?
    var keyGenerations: [RelayV2KeyGeneration]
    var currentGeneration: UInt32
    var agentRouteID: String?
    var agentAgreementPublicKey: Data?
    var agentSigningPublicKey: Data?
    var agentKeyGeneration: UInt32?
    var agentAgreementKeyGenerations: [RelayV2RemoteAgreementKey]? = nil
    var appAttestKeyID: String?
    var outboundEncryptedMessageCount: UInt64? = nil

    static func makeUnpaired(accountID: String = "acc_\(UUID().uuidString.lowercased())") -> RelayV2Identity {
        let agreement = RelayV2Crypto.generateAgreementKeyPair()
        let signing = RelayV2Crypto.generateSigningKeyPair()
        let generation = RelayV2KeyGeneration(
            generation: 1,
            agreementPrivateKey: agreement.privateKey,
            signingPrivateKey: signing.privateKey,
            createdAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000)
        )
        return RelayV2Identity(
            accountID: accountID,
            deviceID: "dev_\(UUID().uuidString.lowercased())",
            hubURL: nil,
            streamID: nil,
            relayInstanceID: nil,
            routeID: nil,
            grantID: nil,
            keyGenerations: [generation],
            currentGeneration: 1,
            agentRouteID: nil,
            agentAgreementPublicKey: nil,
            agentSigningPublicKey: nil,
            agentKeyGeneration: nil,
            appAttestKeyID: nil
        )
    }

    var currentKeys: RelayV2KeyGeneration? {
        keyGenerations.first { $0.generation == currentGeneration }
    }

    var recipientPrivateKeys: [UInt32: Data] {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        return Dictionary(uniqueKeysWithValues: keyGenerations
            .filter { $0.notAfterMilliseconds.map { $0 > now } ?? true }
            .map { ($0.generation, $0.agreementPrivateKey) })
    }

    func activeAgentAgreementKeys(nowMilliseconds: UInt64) -> [RelayV2RemoteAgreementKey] {
        let migrated = agentAgreementKeyGenerations ?? []
        if !migrated.isEmpty {
            return migrated.filter { $0.notAfterMilliseconds.map { $0 > nowMilliseconds } ?? true }
        }
        guard let generation = agentKeyGeneration, let publicKey = agentAgreementPublicKey else {
            return []
        }
        return [.init(generation: generation, publicKey: publicKey, notAfterMilliseconds: nil)]
    }
}

/// The only key material shared with the Notification Service Extension.
/// Chat signing keys, Hub authorization keys, and grants remain app-only.
struct RelayV2PreviewKeyRecord: Codable, Equatable, Sendable {
    let accountID: String
    let privateKey: Data
    let agentAgreementPublicKey: Data
    let generation: UInt32
    var agentGeneration: UInt32? = nil
    var agentAgreementKeyGenerations: [RelayV2RemoteAgreementKey]? = nil
    var localKeyGenerations: [RelayV2LocalPreviewKey]? = nil

    func activeAgentAgreementKeys(nowMilliseconds: UInt64) -> [RelayV2RemoteAgreementKey] {
        let migrated = agentAgreementKeyGenerations ?? []
        if !migrated.isEmpty {
            return migrated.filter { $0.notAfterMilliseconds.map { $0 > nowMilliseconds } ?? true }
        }
        return [.init(
            generation: agentGeneration ?? 1,
            publicKey: agentAgreementPublicKey,
            notAfterMilliseconds: nil
        )]
    }

    func activePrivateKeys(nowMilliseconds: UInt64) -> [RelayV2LocalPreviewKey] {
        let migrated = localKeyGenerations ?? []
        if !migrated.isEmpty {
            return migrated.filter { $0.notAfterMilliseconds.map { $0 > nowMilliseconds } ?? true }
        }
        return [.init(generation: generation, privateKey: privateKey, notAfterMilliseconds: nil)]
    }
}

enum RelayV2PreviewPolicy: String, CaseIterable, Identifiable, Sendable {
    static let defaultsKey = "hermes.relayV2.previewPolicy"
    case afterFirstUnlock = "after_first_unlock"
    case whenUnlocked = "when_unlocked"
    case disabled

    var id: String { rawValue }
    var label: String {
        switch self {
        case .afterFirstUnlock: "Show decrypted previews on lock screen"
        case .whenUnlocked: "Generic notifications while locked"
        case .disabled: "Notifications disabled"
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: defaultsKey),
              let value = Self(rawValue: raw) else { return .afterFirstUnlock }
        return value
    }
}

struct RelayV2PushRegistrationState: Codable, Equatable, Sendable {
    let accountID: String
    var endpointID: String?
    var appAttestKeyID: String
    var pendingAttestation: Data?
    var pendingRequestBody: Data?
    var pendingRequestExpiresAtMilliseconds: UInt64?
    var attestationPhase: RelayV2AttestationPhase = .keyGenerated
    let installationNonce: Data
    let previewPublicKey: Data
    let environment: RelayV2APNsEnvironment
    /// Exact successful response retained until PairInit is durable. This closes
    /// the crash window after the server commits enrollment but before pairing
    /// has copied the one-time bind/activation tokens into its own journal.
    var committedResponseData: Data? = nil
}

enum RelayV2AttestationPhase: String, Codable, Sendable {
    case keyGenerated = "key_generated"
    case attestationStarted = "attestation_started"
    case attestationReturned = "attestation_returned"
    case requestReady = "request_ready"
    case recoveryStarted = "recovery_started"
    case recoveryRequestReady = "recovery_request_ready"
    case committed
}

struct RelayV2HubActivationState: Codable, Equatable, Sendable {
    let accountID: String
    var appAttestKeyID: String
    var isAttested: Bool
    var pendingAttestation: Data?
    var pendingRequestBody: Data?
    var pendingRequestExpiresAtMilliseconds: UInt64?
    var attestationPhase: RelayV2AttestationPhase = .keyGenerated
    let installationNonce: Data
    let environment: RelayV2APNsEnvironment
    var committedResponseData: Data? = nil
}

struct RelayV2PendingLocalRotation: Codable, Equatable, Sendable {
    let accountID: String
    let purpose: String
    let generation: UInt32
    let previousNotAfterMilliseconds: UInt64
    let envelope: RelayV2OuterEnvelope
    let updatedIdentity: RelayV2Identity?
    let updatedPreview: RelayV2PreviewKeyRecord?
}

/// Durable v1→v2 cutover journal. The old gateway credential is secret, so the
/// exact DELETE intent lives in this device-only Keychain item rather than
/// UserDefaults. All legacy fields are either present together or absent when
/// the old account had no push registration.
struct RelayV2MigrationIntent: Codable, Equatable, Sendable {
    let accountID: String
    let legacyBaseURL: URL?
    let legacySessionToken: String?
    let legacyAPNsToken: String?
    let legacyPathStyle: String?
    let createdAtMilliseconds: Int64

    var hasLegacyPushCleanup: Bool {
        legacyBaseURL != nil && legacySessionToken != nil
            && legacyAPNsToken != nil && legacyPathStyle != nil
    }
}

struct RelayV2KeychainStore: @unchecked Sendable {
    static let service = "ai.hermes.mobile.relay.v2"
    static var previewAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "RelayPreviewAccessGroup") as? String
    }

    let service: String
    let previewAccessGroup: String?

    init(
        service: String = RelayV2KeychainStore.service,
        previewAccessGroup: String? = RelayV2KeychainStore.previewAccessGroup
    ) {
        self.service = service
        self.previewAccessGroup = previewAccessGroup
    }

    func saveIdentity(_ identity: RelayV2Identity) throws {
        try save(
            JSONEncoder().encode(identity),
            account: "identity.\(identity.accountID)",
            accessGroup: nil
        )
    }

    func loadIdentity(accountID: String) throws -> RelayV2Identity? {
        guard let data = try load(account: "identity.\(accountID)", accessGroup: nil) else {
            return nil
        }
        return try JSONDecoder().decode(RelayV2Identity.self, from: data)
    }

    func deleteIdentity(accountID: String) {
        delete(account: "identity.\(accountID)", accessGroup: nil)
        deletePreviewKey(accountID: accountID)
    }

    func savePreviewKey(
        _ record: RelayV2PreviewKeyRecord,
        policy: RelayV2PreviewPolicy = .current()
    ) throws {
        let data = try JSONEncoder().encode(record)
        if policy == .disabled {
            try save(
                data, account: "preview.disabled.\(record.accountID)", accessGroup: nil,
                accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            )
            delete(account: "preview.\(record.accountID)", accessGroup: previewAccessGroup)
            return
        }
        let accessible = policy == .whenUnlocked
            ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try save(
            data, account: "preview.\(record.accountID)", accessGroup: previewAccessGroup,
            accessible: accessible
        )
        delete(account: "preview.disabled.\(record.accountID)", accessGroup: nil)
    }

    func loadPreviewKey(accountID: String) throws -> RelayV2PreviewKeyRecord? {
        guard let data = try load(
            account: "preview.\(accountID)",
            accessGroup: previewAccessGroup
        ) else { return nil }
        return try JSONDecoder().decode(RelayV2PreviewKeyRecord.self, from: data)
    }

    /// The extension may run without any app process or selected-account state.
    /// Enumerating this service/access-group returns preview-only records and no
    /// chat identity, signing key, Hub grant, or gateway credential.
    func loadAllPreviewKeys() throws -> [RelayV2PreviewKeyRecord] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let previewAccessGroup { query[kSecAttrAccessGroup as String] = previewAccessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw RelayV2ProtocolError.transport("Keychain preview read failed (\(status))")
        }
        let values: [Data]
        if let array = result as? [Data] { values = array }
        else if let data = result as? Data { values = [data] }
        else { values = [] }
        return values.compactMap { try? JSONDecoder().decode(RelayV2PreviewKeyRecord.self, from: $0) }
    }

    func deletePreviewKey(accountID: String) {
        delete(account: "preview.\(accountID)", accessGroup: previewAccessGroup)
        delete(account: "preview.disabled.\(accountID)", accessGroup: nil)
    }

    func applyPreviewPolicy(_ policy: RelayV2PreviewPolicy, accountID: String) throws {
        let shared = try loadPreviewKey(accountID: accountID)
        let disabled: RelayV2PreviewKeyRecord?
        if let data = try load(account: "preview.disabled.\(accountID)", accessGroup: nil) {
            disabled = try JSONDecoder().decode(RelayV2PreviewKeyRecord.self, from: data)
        } else {
            disabled = nil
        }
        guard let record = shared ?? disabled else { return }
        try savePreviewKey(record, policy: policy)
    }

    func savePushRegistrationState(_ state: RelayV2PushRegistrationState) throws {
        try save(JSONEncoder().encode(state), account: "push.\(state.accountID)", accessGroup: nil)
    }

    func loadPushRegistrationState(accountID: String) throws -> RelayV2PushRegistrationState? {
        guard let data = try load(account: "push.\(accountID)", accessGroup: nil) else { return nil }
        return try JSONDecoder().decode(RelayV2PushRegistrationState.self, from: data)
    }

    func saveHubActivationState(_ state: RelayV2HubActivationState) throws {
        try save(JSONEncoder().encode(state), account: "activation.\(state.accountID)", accessGroup: nil)
    }

    func loadHubActivationState(accountID: String) throws -> RelayV2HubActivationState? {
        guard let data = try load(account: "activation.\(accountID)", accessGroup: nil) else { return nil }
        return try JSONDecoder().decode(RelayV2HubActivationState.self, from: data)
    }


    /// Atomically-at-the-Keychain-item level re-keys enrollment state from the
    /// short-lived pairing offer namespace to the durable account namespace.
    /// The destination is written before the temporary item is deleted, so a
    /// crash can leave a harmless duplicate but can never lose committed state.
    func migrateEnrollmentState(from temporaryAccountID: String, to accountID: String) throws {
        guard temporaryAccountID != accountID else {
            try scrubConsumedEnrollmentCredentials(accountID: accountID)
            return
        }
        if let push = try loadPushRegistrationState(accountID: temporaryAccountID) {
            try savePushRegistrationState(.init(
                accountID: accountID,
                endpointID: push.endpointID,
                appAttestKeyID: push.appAttestKeyID,
                pendingAttestation: nil,
                pendingRequestBody: nil,
                pendingRequestExpiresAtMilliseconds: nil,
                attestationPhase: push.attestationPhase,
                installationNonce: push.installationNonce,
                previewPublicKey: push.previewPublicKey,
                environment: push.environment,
                committedResponseData: nil
            ))
        }
        if let activation = try loadHubActivationState(accountID: temporaryAccountID) {
            try saveHubActivationState(.init(
                accountID: accountID,
                appAttestKeyID: activation.appAttestKeyID,
                isAttested: activation.isAttested,
                pendingAttestation: nil,
                pendingRequestBody: nil,
                pendingRequestExpiresAtMilliseconds: nil,
                attestationPhase: activation.attestationPhase,
                installationNonce: activation.installationNonce,
                environment: activation.environment,
                committedResponseData: nil
            ))
        }
        deleteEnrollmentState(accountID: temporaryAccountID)
    }

    /// Once PairInit is durably encrypted, enrollment responses and retry
    /// bodies are consumed. Keep only the endpoint/attestation metadata needed
    /// for later token refresh; erase bind/activation-bearing response bytes.
    func scrubConsumedEnrollmentCredentials(accountID: String) throws {
        if var push = try loadPushRegistrationState(accountID: accountID) {
            push.pendingAttestation = nil
            push.pendingRequestBody = nil
            push.pendingRequestExpiresAtMilliseconds = nil
            push.committedResponseData = nil
            try savePushRegistrationState(push)
        }
        if var activation = try loadHubActivationState(accountID: accountID) {
            activation.pendingAttestation = nil
            activation.pendingRequestBody = nil
            activation.pendingRequestExpiresAtMilliseconds = nil
            activation.committedResponseData = nil
            try saveHubActivationState(activation)
        }
    }

    func deleteEnrollmentState(accountID: String) {
        delete(account: "push.\(accountID)", accessGroup: nil)
        delete(account: "activation.\(accountID)", accessGroup: nil)
    }

    func savePendingLocalRotation(_ rotation: RelayV2PendingLocalRotation) throws {
        try save(
            JSONEncoder().encode(rotation),
            account: "rotation.pending.\(rotation.accountID)",
            accessGroup: nil
        )
    }

    func loadPendingLocalRotation(accountID: String) throws -> RelayV2PendingLocalRotation? {
        guard let data = try load(
            account: "rotation.pending.\(accountID)", accessGroup: nil
        ) else { return nil }
        return try JSONDecoder().decode(RelayV2PendingLocalRotation.self, from: data)
    }

    func deletePendingLocalRotation(accountID: String) {
        delete(account: "rotation.pending.\(accountID)", accessGroup: nil)
    }

    func savePendingPairingData(_ data: Data) throws {
        try save(data, account: "pairing.pending", accessGroup: nil)
    }

    func loadPendingPairingData() throws -> Data? {
        try load(account: "pairing.pending", accessGroup: nil)
    }

    func deletePendingPairing() {
        delete(account: "pairing.pending", accessGroup: nil)
    }

    func savePendingPairingEnrollmentData(_ data: Data) throws {
        try save(data, account: "pairing.enrollment.pending", accessGroup: nil)
    }

    func loadPendingPairingEnrollmentData() throws -> Data? {
        try load(account: "pairing.enrollment.pending", accessGroup: nil)
    }

    func deletePendingPairingEnrollment() {
        delete(account: "pairing.enrollment.pending", accessGroup: nil)
    }

    func saveMigrationIntent(_ intent: RelayV2MigrationIntent) throws {
        try save(
            JSONEncoder().encode(intent),
            account: "migration.v1-to-v2.pending",
            accessGroup: nil
        )
    }

    func loadMigrationIntent() throws -> RelayV2MigrationIntent? {
        guard let data = try load(
            account: "migration.v1-to-v2.pending",
            accessGroup: nil
        ) else { return nil }
        return try JSONDecoder().decode(RelayV2MigrationIntent.self, from: data)
    }

    func deleteMigrationIntent() {
        delete(account: "migration.v1-to-v2.pending", accessGroup: nil)
    }

    private func save(
        _ data: Data,
        account: String,
        accessGroup: String?,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) throws {
        var query = baseQuery(account: account, accessGroup: accessGroup)
        query[kSecAttrAccessible as String] = accessible
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: accessible,
            ]
            let updated = SecItemUpdate(
                baseQuery(account: account, accessGroup: accessGroup) as CFDictionary,
                update as CFDictionary
            )
            guard updated == errSecSuccess else {
                throw RelayV2ProtocolError.transport("Keychain update failed (\(updated))")
            }
        } else if status != errSecSuccess {
            throw RelayV2ProtocolError.transport("Keychain write failed (\(status))")
        }
    }

    private func load(account: String, accessGroup: String?) throws -> Data? {
        var query = baseQuery(account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RelayV2ProtocolError.transport("Keychain read failed (\(status))")
        }
        return data
    }

    private func delete(account: String, accessGroup: String?) {
        SecItemDelete(baseQuery(account: account, accessGroup: accessGroup) as CFDictionary)
    }

    private func baseQuery(account: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
