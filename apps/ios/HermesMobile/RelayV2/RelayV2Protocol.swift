import CryptoKit
import Foundation
import Security

enum RelayV2 {
    static let protocolVersion = 2
    static let maximumPreviewPlaintextBytes = 1_200
    // JSONValue stores numeric scalars as Double. HRP/2 therefore caps every
    // JSON integer at IEEE-754's exact range so no platform can round a wire
    // sequence, revision, or timestamp into a different durable value.
    static let maximumJSONInteger: UInt64 = 9_007_199_254_740_991
    static let maximumJSONIntegerInt64: Int64 = 9_007_199_254_740_991
    static let maximumExactlyRepresentableJSONInteger = 9_007_199_254_740_991.0
}

enum RelayV2TransportClass: String, Codable, CaseIterable, Sendable {
    case realtime
    case state
    case command
    case control
}

enum RelayV2SecureMessageKind: String, Codable, CaseIterable, Sendable {
    case pairInit = "pair.init"
    case pairAccept = "pair.accept"
    case pairConfirm = "pair.confirm"
    case frameBatch = "frame_batch"
    case checkpoint
    case rpcRequest = "rpc_request"
    case rpcResponse = "rpc_response"
    case streamAck = "stream_ack"
    case syncRequest = "sync_request"
    case keyRotate = "key_rotate"
    case deviceRevoke = "device_revoke"
    case deliveryReceipt = "delivery_receipt"
}

enum RelayV2NotificationClass: String, Codable, CaseIterable, Sendable {
    case update
    case approval
    case error
}

enum RelayV2APNsEnvironment: String, Codable, Sendable {
    case production
    case sandbox
}

enum RelayV2HPKEPurpose: String, Sendable {
    case chat
    case notification
    case control
}

enum RelayV2HPKEDirection: String, Sendable {
    case agentToDevice = "agent-to-device"
    case deviceToAgent = "device-to-agent"
}

enum RelayV2ErrorCode: String, Codable, Sendable {
    case invalidArgument = "INVALID_ARGUMENT"
    case unauthenticated = "UNAUTHENTICATED"
    case revoked = "REVOKED"
    case expired = "EXPIRED"
    case unsupportedVersion = "UNSUPPORTED_VERSION"
    case notFound = "NOT_FOUND"
    case conflict = "CONFLICT"
    case alreadyResolved = "ALREADY_RESOLVED"
    case gatewayOffline = "GATEWAY_OFFLINE"
    case gatewayAmbiguous = "GATEWAY_AMBIGUOUS"
    case mailboxFull = "MAILBOX_FULL"
    case rateLimited = "RATE_LIMITED"
    case `internal` = "INTERNAL"
}

enum RelayV2ProtocolError: Error, LocalizedError, Equatable, Sendable {
    case invalidArgument(field: String?)
    case unauthenticated
    case revoked
    case expired
    case unsupportedVersion(Int)
    case replayDetected
    case keyGenerationUnavailable(UInt32)
    case conflict(String)
    case remote(RelayV2ErrorCode, retryAfterSeconds: Double?)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let field):
            field.map { "Invalid HRP/2 field: \($0)" } ?? "Invalid HRP/2 argument"
        case .unauthenticated: "HRP/2 message authentication failed"
        case .revoked: "The relay credential was revoked"
        case .expired: "The relay message expired"
        case .unsupportedVersion(let value): "Unsupported relay protocol version \(value)"
        case .replayDetected: "The relay message was already processed"
        case .keyGenerationUnavailable(let value): "Relay key generation \(value) is unavailable"
        case .conflict(let message): message
        case .remote(let code, let retryAfter):
            retryAfter.map { "Relay Hub rejected the request (\(code.rawValue)); retry after \(Int($0)) seconds" }
                ?? "Relay Hub rejected the request (\(code.rawValue))"
        case .transport(let message): message
        }
    }
}

struct RelayV2OuterHeader: Codable, Equatable, Sendable {
    let version: Int
    let source: String
    let destination: String
    let messageID: String
    let messageClass: RelayV2TransportClass
    let expiresAtMilliseconds: UInt64
    let recipientKeyGeneration: UInt32
    let collapse: String?

    init(
        version: Int = RelayV2.protocolVersion,
        source: String,
        destination: String,
        messageID: String,
        messageClass: RelayV2TransportClass,
        expiresAtMilliseconds: UInt64,
        recipientKeyGeneration: UInt32,
        collapse: String? = nil
    ) throws {
        guard version == RelayV2.protocolVersion else {
            throw RelayV2ProtocolError.unsupportedVersion(version)
        }
        guard RelayV2Wire.isToken(source), RelayV2Wire.isToken(destination) else {
            throw RelayV2ProtocolError.invalidArgument(field: "route")
        }
        guard (try? RelayV2Wire.decodeBase64URL(messageID, exactBytes: 16)) != nil else {
            throw RelayV2ProtocolError.invalidArgument(field: "mid")
        }
        guard recipientKeyGeneration > 0 else {
            throw RelayV2ProtocolError.invalidArgument(field: "recipient_key_generation")
        }
        guard expiresAtMilliseconds <= RelayV2.maximumJSONInteger else {
            throw RelayV2ProtocolError.invalidArgument(field: "expires_at_ms")
        }
        if let collapse, !RelayV2Wire.isCollapseToken(collapse) {
            throw RelayV2ProtocolError.invalidArgument(field: "collapse")
        }
        self.version = version
        self.source = source
        self.destination = destination
        self.messageID = messageID
        self.messageClass = messageClass
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.recipientKeyGeneration = recipientKeyGeneration
        self.collapse = collapse
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version = "v"
        case source = "src"
        case destination = "dst"
        case messageID = "mid"
        case messageClass = "class"
        case expiresAtMilliseconds = "expires_at_ms"
        case recipientKeyGeneration = "recipient_key_generation"
        case collapse
    }

    var authenticatedData: Data {
        transcript(domain: Data("HRA2".utf8))
    }

    func signaturePayload(encapsulatedKey: Data, ciphertext: Data) -> Data {
        let digest = Data(SHA256.hash(data: encapsulatedKey + ciphertext))
        return transcript(domain: Data("HRH2".utf8), suffix: [digest])
    }

    private func transcript(domain: Data, suffix: [Data] = []) -> Data {
        let fields: [Data] = [
            RelayV2Wire.bigEndian(UInt16(version)),
            Data(source.utf8),
            Data(destination.utf8),
            Data(messageID.utf8),
            Data(messageClass.rawValue.utf8),
            RelayV2Wire.bigEndian(expiresAtMilliseconds),
            RelayV2Wire.bigEndian(recipientKeyGeneration),
            collapse.map { Data($0.utf8) } ?? Data(),
        ] + suffix
        return RelayV2Wire.lengthPrefixed(domain: domain, fields: fields)
    }
}

struct RelayV2OuterEnvelope: Codable, Equatable, Sendable {
    let header: RelayV2OuterHeader
    let encapsulatedKey: Data
    let ciphertext: Data
    let signature: Data

    init(
        header: RelayV2OuterHeader,
        encapsulatedKey: Data,
        ciphertext: Data,
        signature: Data
    ) throws {
        guard encapsulatedKey.count == 32 else {
            throw RelayV2ProtocolError.invalidArgument(field: "enc")
        }
        guard (16...262_160).contains(ciphertext.count) else {
            throw RelayV2ProtocolError.invalidArgument(field: "ct")
        }
        guard signature.count == 64 else {
            throw RelayV2ProtocolError.invalidArgument(field: "sig")
        }
        self.header = header
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version = "v"
        case source = "src"
        case destination = "dst"
        case messageID = "mid"
        case messageClass = "class"
        case expiresAtMilliseconds = "expires_at_ms"
        case recipientKeyGeneration = "recipient_key_generation"
        case collapse
        case encapsulatedKey = "enc"
        case ciphertext = "ct"
        case signature = "sig"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let source = try container.decode(String.self, forKey: .source)
        let destination = try container.decode(String.self, forKey: .destination)
        let messageID = try container.decode(String.self, forKey: .messageID)
        let messageClass = try container.decode(RelayV2TransportClass.self, forKey: .messageClass)
        let expiry = try container.decode(UInt64.self, forKey: .expiresAtMilliseconds)
        let generation = try container.decode(UInt32.self, forKey: .recipientKeyGeneration)
        let collapse = try container.decodeIfPresent(String.self, forKey: .collapse)
        self.header = try RelayV2OuterHeader(
            version: version,
            source: source,
            destination: destination,
            messageID: messageID,
            messageClass: messageClass,
            expiresAtMilliseconds: expiry,
            recipientKeyGeneration: generation,
            collapse: collapse
        )
        self.encapsulatedKey = try RelayV2Wire.decodeBase64URL(
            container.decode(String.self, forKey: .encapsulatedKey), exactBytes: 32
        )
        self.ciphertext = try RelayV2Wire.decodeBase64URL(
            container.decode(String.self, forKey: .ciphertext), minimumBytes: 16, maximumBytes: 262_160
        )
        self.signature = try RelayV2Wire.decodeBase64URL(
            container.decode(String.self, forKey: .signature), exactBytes: 64
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(header.version, forKey: .version)
        try container.encode(header.source, forKey: .source)
        try container.encode(header.destination, forKey: .destination)
        try container.encode(header.messageID, forKey: .messageID)
        try container.encode(header.messageClass, forKey: .messageClass)
        try container.encode(header.expiresAtMilliseconds, forKey: .expiresAtMilliseconds)
        try container.encode(header.recipientKeyGeneration, forKey: .recipientKeyGeneration)
        try container.encodeIfPresent(header.collapse, forKey: .collapse)
        if header.collapse == nil { try container.encodeNil(forKey: .collapse) }
        try container.encode(RelayV2Wire.base64URL(encapsulatedKey), forKey: .encapsulatedKey)
        try container.encode(RelayV2Wire.base64URL(ciphertext), forKey: .ciphertext)
        try container.encode(RelayV2Wire.base64URL(signature), forKey: .signature)
    }

    static func decodeStrict(from data: Data) throws -> RelayV2OuterEnvelope {
        try RelayV2Wire.requireExactObjectKeys(data, keys: Set(CodingKeys.allCases.map(\.rawValue)))
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func canonicalJSON() throws -> Data { try RelayV2Wire.canonicalJSON(self) }
}

struct RelayV2SecureMessage: Codable, Equatable, Sendable {
    let version: Int
    let messageID: String
    let kind: RelayV2SecureMessageKind
    let senderKeyGeneration: UInt32
    let createdAtMilliseconds: UInt64
    let expiresAtMilliseconds: UInt64
    let body: [String: JSONValue]

    init(
        version: Int = RelayV2.protocolVersion,
        messageID: String,
        kind: RelayV2SecureMessageKind,
        senderKeyGeneration: UInt32,
        createdAtMilliseconds: UInt64,
        expiresAtMilliseconds: UInt64,
        body: [String: JSONValue]
    ) throws {
        guard version == RelayV2.protocolVersion else {
            throw RelayV2ProtocolError.unsupportedVersion(version)
        }
        guard (try? RelayV2Wire.decodeBase64URL(messageID, exactBytes: 16)) != nil else {
            throw RelayV2ProtocolError.invalidArgument(field: "mid")
        }
        guard senderKeyGeneration > 0 else {
            throw RelayV2ProtocolError.invalidArgument(field: "sender_key_generation")
        }
        guard createdAtMilliseconds <= RelayV2.maximumJSONInteger,
              expiresAtMilliseconds <= RelayV2.maximumJSONInteger,
              createdAtMilliseconds <= expiresAtMilliseconds else {
            throw RelayV2ProtocolError.invalidArgument(field: "expires_at_ms")
        }
        guard RelayV2Wire.containsOnlyCanonicalIntegerNumbers(.object(body)) else {
            throw RelayV2ProtocolError.invalidArgument(field: "body_number")
        }
        self.version = version
        self.messageID = messageID
        self.kind = kind
        self.senderKeyGeneration = senderKeyGeneration
        self.createdAtMilliseconds = createdAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.body = body
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version = "v"
        case messageID = "mid"
        case kind
        case senderKeyGeneration = "sender_key_generation"
        case createdAtMilliseconds = "created_at_ms"
        case expiresAtMilliseconds = "expires_at_ms"
        case body
    }

    static func decodeStrict(from data: Data) throws -> RelayV2SecureMessage {
        try RelayV2Wire.requireExactObjectKeys(data, keys: Set(CodingKeys.allCases.map(\.rawValue)))
        try RelayV2Wire.requireNoFloatingPointJSON(from: data)
        try RelayV2Wire.requireSharedIntegerRange(from: data)
        let value = try JSONDecoder().decode(Self.self, from: data)
        return try Self(
            version: value.version,
            messageID: value.messageID,
            kind: value.kind,
            senderKeyGeneration: value.senderKeyGeneration,
            createdAtMilliseconds: value.createdAtMilliseconds,
            expiresAtMilliseconds: value.expiresAtMilliseconds,
            body: value.body
        )
    }

    func canonicalJSON() throws -> Data { try RelayV2Wire.canonicalJSON(self) }
}

struct RelayV2NotificationPreview: Codable, Equatable, Sendable {
    let version: Int
    let notificationID: String
    let notificationClass: RelayV2NotificationClass
    let title: String
    let body: String
    let threadToken: String
    let category: String?
    let expiresAtMilliseconds: UInt64
    let action: [String: JSONValue]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version = "v"
        case notificationID = "notification_id"
        case notificationClass = "class"
        case title, body
        case threadToken = "thread_token"
        case category
        case expiresAtMilliseconds = "expires_at_ms"
        case action
    }

    init(
        version: Int = RelayV2.protocolVersion,
        notificationID: String,
        notificationClass: RelayV2NotificationClass,
        title: String,
        body: String,
        threadToken: String,
        category: String?,
        expiresAtMilliseconds: UInt64,
        action: [String: JSONValue]?
    ) throws {
        guard version == RelayV2.protocolVersion else {
            throw RelayV2ProtocolError.unsupportedVersion(version)
        }
        guard RelayV2Wire.isToken(notificationID), RelayV2Wire.isToken(threadToken),
              !title.isEmpty, Data(title.utf8).count <= 200,
              !body.isEmpty, Data(body.utf8).count <= 1_200,
              category.map(RelayV2Wire.isToken) ?? true,
              expiresAtMilliseconds <= RelayV2.maximumJSONInteger else {
            throw RelayV2ProtocolError.invalidArgument(field: "notification_preview")
        }
        guard action.map({ RelayV2Wire.containsOnlyCanonicalIntegerNumbers(.object($0)) }) ?? true else {
            throw RelayV2ProtocolError.invalidArgument(field: "action_number")
        }
        try Self.validateAction(
            action,
            notificationClass: notificationClass,
            category: category
        )
        self.version = version
        self.notificationID = notificationID
        self.notificationClass = notificationClass
        self.title = title
        self.body = body
        self.threadToken = threadToken
        self.category = category
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.action = action
        guard (try canonicalJSON()).count <= RelayV2.maximumPreviewPlaintextBytes else {
            throw RelayV2ProtocolError.invalidArgument(field: "preview")
        }
    }

    func canonicalJSON() throws -> Data {
        let data = try RelayV2Wire.canonicalJSON(self)
        guard data.count <= RelayV2.maximumPreviewPlaintextBytes else {
            throw RelayV2ProtocolError.invalidArgument(field: "preview")
        }
        return data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(notificationID, forKey: .notificationID)
        try container.encode(notificationClass, forKey: .notificationClass)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(threadToken, forKey: .threadToken)
        if let category { try container.encode(category, forKey: .category) }
        else { try container.encodeNil(forKey: .category) }
        try container.encode(expiresAtMilliseconds, forKey: .expiresAtMilliseconds)
        if let action { try container.encode(action, forKey: .action) }
        else { try container.encodeNil(forKey: .action) }
    }

    static func decodeStrict(from data: Data) throws -> RelayV2NotificationPreview {
        guard data.count <= RelayV2.maximumPreviewPlaintextBytes else {
            throw RelayV2ProtocolError.invalidArgument(field: "preview")
        }
        try RelayV2Wire.requireExactObjectKeys(data, keys: Set(CodingKeys.allCases.map(\.rawValue)))
        try RelayV2Wire.requireNoFloatingPointJSON(from: data)
        try RelayV2Wire.requireSharedIntegerRange(from: data)
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == RelayV2.protocolVersion else {
            throw RelayV2ProtocolError.unsupportedVersion(value.version)
        }
        guard RelayV2Wire.isToken(value.notificationID), RelayV2Wire.isToken(value.threadToken) else {
            throw RelayV2ProtocolError.invalidArgument(field: "notification_id")
        }
        guard !value.title.isEmpty, Data(value.title.utf8).count <= 200,
              !value.body.isEmpty, Data(value.body.utf8).count <= 1_200 else {
            throw RelayV2ProtocolError.invalidArgument(field: "preview_text")
        }
        if let category = value.category, !RelayV2Wire.isToken(category) {
            throw RelayV2ProtocolError.invalidArgument(field: "category")
        }
        return try Self(
            version: value.version,
            notificationID: value.notificationID,
            notificationClass: value.notificationClass,
            title: value.title,
            body: value.body,
            threadToken: value.threadToken,
            category: value.category,
            expiresAtMilliseconds: value.expiresAtMilliseconds,
            action: value.action
        )
    }

    private static func validateAction(
        _ action: [String: JSONValue]?,
        notificationClass: RelayV2NotificationClass,
        category: String?
    ) throws {
        if notificationClass != .approval {
            guard action == nil, category == nil else {
                throw RelayV2ProtocolError.invalidArgument(field: "notification_action")
            }
            return
        }
        guard category == "HERMES_APPROVAL", let action,
              Set(action.keys) == ["request_id", "session_id", "capability", "allowed_decisions",
                                   "destructive", "device_id", "device_generation"],
              let requestID = action["request_id"]?.stringValue, RelayV2Wire.isToken(requestID),
              let sessionID = action["session_id"]?.stringValue, RelayV2Wire.isToken(sessionID),
              let capability = action["capability"]?.stringValue, RelayV2Wire.isToken(capability),
              let deviceID = action["device_id"]?.stringValue, RelayV2Wire.isToken(deviceID),
              action["device_generation"]?.intValue.map({ $0 > 0 }) == true,
              action["destructive"]?.boolValue != nil,
              let decisions = action["allowed_decisions"]?.arrayValue?.compactMap(\.stringValue),
              decisions.count == action["allowed_decisions"]?.arrayValue?.count,
              !decisions.isEmpty,
              Set(decisions).count == decisions.count,
              Set(decisions).isSubset(of: ["approve_once", "deny"]) else {
            throw RelayV2ProtocolError.invalidArgument(field: "notification_action")
        }
    }
}

struct RelayV2NotificationDescriptor: Codable, Equatable, Sendable {
    let version: Int
    let notificationClass: RelayV2NotificationClass
    let notificationID: String
    let previewEncapsulatedKey: Data
    let previewCiphertext: Data
    let collapseID: String?
    let expiresAtMilliseconds: UInt64
    let sound: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version = "v"
        case notificationClass = "class"
        case notificationID = "notification_id"
        case previewEncapsulatedKey = "preview_enc"
        case previewCiphertext = "preview_ct"
        case collapseID = "collapse_id"
        case expiresAtMilliseconds = "expires_at_ms"
        case sound
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.notificationClass = try container.decode(RelayV2NotificationClass.self, forKey: .notificationClass)
        self.notificationID = try container.decode(String.self, forKey: .notificationID)
        self.previewEncapsulatedKey = try RelayV2Wire.decodeBase64URL(
            container.decode(String.self, forKey: .previewEncapsulatedKey), exactBytes: 32
        )
        self.previewCiphertext = try RelayV2Wire.decodeBase64URL(
            container.decode(String.self, forKey: .previewCiphertext), minimumBytes: 16, maximumBytes: 4_096
        )
        self.collapseID = try container.decodeIfPresent(String.self, forKey: .collapseID)
        self.expiresAtMilliseconds = try container.decode(UInt64.self, forKey: .expiresAtMilliseconds)
        self.sound = try container.decode(Bool.self, forKey: .sound)
        guard version == RelayV2.protocolVersion,
              RelayV2Wire.isToken(notificationID),
              collapseID.map(RelayV2Wire.isCollapseToken) ?? true,
              expiresAtMilliseconds <= RelayV2.maximumJSONInteger else {
            throw RelayV2ProtocolError.invalidArgument(field: "notification_descriptor")
        }
    }

    init(
        version: Int = RelayV2.protocolVersion,
        notificationClass: RelayV2NotificationClass,
        notificationID: String,
        previewEncapsulatedKey: Data,
        previewCiphertext: Data,
        collapseID: String?,
        expiresAtMilliseconds: UInt64,
        sound: Bool
    ) throws {
        guard version == RelayV2.protocolVersion,
              RelayV2Wire.isToken(notificationID),
              previewEncapsulatedKey.count == 32,
              (16...4_096).contains(previewCiphertext.count),
              collapseID.map(RelayV2Wire.isCollapseToken) ?? true,
              expiresAtMilliseconds <= RelayV2.maximumJSONInteger else {
            throw RelayV2ProtocolError.invalidArgument(field: "notification_descriptor")
        }
        self.version = version
        self.notificationClass = notificationClass
        self.notificationID = notificationID
        self.previewEncapsulatedKey = previewEncapsulatedKey
        self.previewCiphertext = previewCiphertext
        self.collapseID = collapseID
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.sound = sound
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(notificationClass, forKey: .notificationClass)
        try container.encode(notificationID, forKey: .notificationID)
        try container.encode(RelayV2Wire.base64URL(previewEncapsulatedKey), forKey: .previewEncapsulatedKey)
        try container.encode(RelayV2Wire.base64URL(previewCiphertext), forKey: .previewCiphertext)
        try container.encodeIfPresent(collapseID, forKey: .collapseID)
        if collapseID == nil { try container.encodeNil(forKey: .collapseID) }
        try container.encode(expiresAtMilliseconds, forKey: .expiresAtMilliseconds)
        try container.encode(sound, forKey: .sound)
    }

    var authenticatedData: Data {
        RelayV2Wire.lengthPrefixed(domain: Data("HRN2".utf8), fields: [
            RelayV2Wire.bigEndian(UInt16(version)),
            Data(notificationClass.rawValue.utf8),
            Data(notificationID.utf8),
            RelayV2Wire.bigEndian(expiresAtMilliseconds),
            collapseID.map { Data($0.utf8) } ?? Data(),
            Data([sound ? 1 : 0]),
        ])
    }

    static func decodeStrict(from data: Data) throws -> RelayV2NotificationDescriptor {
        try RelayV2Wire.requireExactObjectKeys(data, keys: Set(CodingKeys.allCases.map(\.rawValue)))
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

enum RelayV2Wire {
    static func hpkeInfo(_ purpose: RelayV2HPKEPurpose, _ direction: RelayV2HPKEDirection) -> Data {
        Data("hermes-mobile/hrp2/\(purpose.rawValue)/\(direction.rawValue)".utf8)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(
        _ value: String,
        exactBytes: Int? = nil,
        minimumBytes: Int = 1,
        maximumBytes: Int? = nil
    ) throws -> Data {
        guard !value.isEmpty, !value.contains("="),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              }) else {
            throw RelayV2ProtocolError.invalidArgument(field: "base64url")
        }
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), base64URL(data) == value else {
            throw RelayV2ProtocolError.invalidArgument(field: "base64url")
        }
        if let exactBytes, data.count != exactBytes {
            throw RelayV2ProtocolError.invalidArgument(field: "base64url")
        }
        guard data.count >= minimumBytes, maximumBytes.map({ data.count <= $0 }) ?? true else {
            throw RelayV2ProtocolError.invalidArgument(field: "base64url")
        }
        return data
    }

    static func isToken(_ value: String) -> Bool {
        let bytes = Data(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 256 else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 46 || byte == 95 || byte == 126 || byte == 45
        }
    }

    static func isCollapseToken(_ value: String) -> Bool {
        let bytes = Data(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 46 || byte == 95 || byte == 126 || byte == 45
        }
    }

    static func randomMessageID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return base64URL(Data(bytes))
    }

    static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func requireExactObjectKeys(_ data: Data, keys: Set<String>) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys else {
            throw RelayV2ProtocolError.invalidArgument(field: "object_keys")
        }
    }

    static func requireNoFloatingPointJSON(from data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard containsNoFloatingPointJSON(root) else {
            throw RelayV2ProtocolError.invalidArgument(field: "floating_point")
        }
    }

    static func requireSharedIntegerRange(from data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard containsOnlySharedRangeIntegers(root) else {
            throw RelayV2ProtocolError.invalidArgument(field: "integer_range")
        }
    }

    static func containsOnlyCanonicalIntegerNumbers(_ value: JSONValue) -> Bool {
        switch value {
        case .number(let number):
            return number.isFinite
                && number.rounded(.towardZero) == number
                && number >= -RelayV2.maximumExactlyRepresentableJSONInteger
                && number <= RelayV2.maximumExactlyRepresentableJSONInteger
        case .array(let values):
            return values.allSatisfy(containsOnlyCanonicalIntegerNumbers)
        case .object(let values):
            return values.values.allSatisfy(containsOnlyCanonicalIntegerNumbers)
        case .null, .bool, .string:
            return true
        }
    }

    private static func containsNoFloatingPointJSON(_ value: Any) -> Bool {
        if let values = value as? [Any] {
            return values.allSatisfy(containsNoFloatingPointJSON)
        }
        if let values = value as? [String: Any] {
            return values.values.allSatisfy(containsNoFloatingPointJSON)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return true }
            return !CFNumberIsFloatType(number)
        }
        return true
    }

    private static func containsOnlySharedRangeIntegers(_ value: Any) -> Bool {
        if let values = value as? [Any] {
            return values.allSatisfy(containsOnlySharedRangeIntegers)
        }
        if let values = value as? [String: Any] {
            return values.values.allSatisfy(containsOnlySharedRangeIntegers)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return true }
            guard let integer = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
            else { return false }
            return integer >= -Decimal(RelayV2.maximumJSONIntegerInt64)
                && integer <= Decimal(RelayV2.maximumJSONIntegerInt64)
        }
        return true
    }

    static func lengthPrefixed(domain: Data, fields: [Data]) -> Data {
        var output = domain
        for field in fields {
            output.append(bigEndian(UInt32(field.count)))
            output.append(field)
        }
        return output
    }

    static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}
