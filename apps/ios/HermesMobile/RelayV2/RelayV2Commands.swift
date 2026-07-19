import CryptoKit
import Foundation
import GRDB

extension Notification.Name {
    static let relayV2CommandQueued = Notification.Name("ai.hermes.relayV2.commandQueued")
}

enum RelayV2Identifiers {
    static func canonicalUUID() -> String { UUID().uuidString.lowercased() }

    static func stableCanonicalUUID(seed: Data) -> String {
        var bytes = Array(SHA256.hash(data: seed).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString.lowercased()
    }

    static func cacheNamespace(accountID: String) -> String {
        let digest = SHA256.hash(data: Data(accountID.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return "relay-v2:\(digest)"
    }
}

enum RelayV2CommandKind: String, Codable, CaseIterable, Sendable {
    case prompt
    case approval
    case interrupt
    case sessionList = "session_list"
    case sessionHistory = "session_history"
    case sessionOpen = "session_open"
    case sessionResume = "session_resume"
    case clarify
    case presenceSet = "presence_set"
}

enum RelayV2CommandState: String, Codable, Sendable {
    case queued
    case sending
    case accepted
    case retryWait = "retry_wait"
    case ambiguous
    case completed
    case expired
}

enum RelayV2RPCRequestFactory {
    static func make(
        kind: RelayV2CommandKind,
        operationID: String,
        clientMessageID: String,
        params: [String: JSONValue]
    ) throws -> [String: JSONValue] {
        let method: String
        var validated = params
        switch kind {
        case .prompt:
            method = "prompt.submit"
            validated["client_message_id"] = .string(clientMessageID)
        case .approval: method = "approval.respond"
        case .interrupt: method = "session.interrupt"
        case .sessionList: method = "session.list"
        case .sessionHistory: method = "session.history"
        case .sessionOpen: method = "session.open"
        case .sessionResume: method = "session.resume"
        case .clarify: method = "clarify.respond"
        case .presenceSet: method = "presence.set"
        }
        return ["jsonrpc": "2.0", "id": .string(clientMessageID), "method": .string(method),
                "params": .object(validated), "op_id": .string(operationID)]
    }
}

struct RelayV2CommandRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "relay_v2_commands"

    let operationID: String
    let clientMessageID: String
    let accountID: String
    let sessionID: String?
    let kind: RelayV2CommandKind
    let payloadJSON: Data
    let payloadHash: String
    var fixedExpiresAt: Double?
    var envelopeJSON: Data?
    var state: RelayV2CommandState
    var attemptCount: Int
    var nextAttemptAt: Double?
    var leaseOwner: String?
    var leaseExpiresAt: Double?
    var lastErrorCode: String?
    let createdAt: Double
    var updatedAt: Double
    var completedAt: Double?

    enum CodingKeys: String, CodingKey {
        case operationID = "op_id"
        case clientMessageID = "client_message_id"
        case accountID = "account_id"
        case sessionID = "session_id"
        case kind
        case payloadJSON = "payload_json"
        case payloadHash = "payload_hash"
        case fixedExpiresAt = "fixed_expires_at"
        case envelopeJSON = "envelope_json"
        case state
        case attemptCount = "attempt_count"
        case nextAttemptAt = "next_attempt_at"
        case leaseOwner = "lease_owner"
        case leaseExpiresAt = "lease_expires_at"
        case lastErrorCode = "last_error_code"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
    }
}

extension WorkRepository {
    @discardableResult
    func enqueueRelayV2Command(
        operationID: String,
        clientMessageID: String,
        accountID: String,
        sessionID: String?,
        kind: RelayV2CommandKind,
        payload: [String: JSONValue],
        now: Date = Date()
    ) async throws -> RelayV2CommandRecord {
        guard RelayV2Wire.isToken(operationID), RelayV2Wire.isToken(clientMessageID),
              RelayV2Wire.isToken(accountID) else {
            throw RelayV2ProtocolError.invalidArgument(field: "operation_id")
        }
        let request = try RelayV2RPCRequestFactory.make(
            kind: kind, operationID: operationID, clientMessageID: clientMessageID, params: payload
        )
        let payloadData = try RelayV2Wire.canonicalJSON(request)
        let payloadHash = SHA256.hash(data: payloadData)
            .map { String(format: "%02x", $0) }.joined()
        let timestamp = now.timeIntervalSince1970
        let record = RelayV2CommandRecord(
            operationID: operationID,
            clientMessageID: clientMessageID,
            accountID: accountID,
            sessionID: sessionID,
            kind: kind,
            payloadJSON: payloadData,
            payloadHash: payloadHash,
            fixedExpiresAt: timestamp + 24 * 60 * 60,
            envelopeJSON: nil,
            state: .queued,
            attemptCount: 0,
            nextAttemptAt: nil,
            leaseOwner: nil,
            leaseExpiresAt: nil,
            lastErrorCode: nil,
            createdAt: timestamp,
            updatedAt: timestamp,
            completedAt: nil
        )
        return try await database.write { db in
            if let existing = try RelayV2CommandRecord.fetchOne(db, key: operationID) {
                guard existing.payloadHash == payloadHash,
                      existing.clientMessageID == clientMessageID else {
                    throw RelayV2ProtocolError.conflict("Operation ID was reused with different content")
                }
                return existing
            }
            try record.insert(db)
            return record
        }
    }

    func claimRelayV2Command(
        accountID: String,
        owner: String,
        now: Date = Date(),
        leaseDuration: TimeInterval = 30
    ) async throws -> RelayV2CommandRecord? {
        guard !owner.isEmpty, leaseDuration > 0 else {
            throw RelayV2ProtocolError.invalidArgument(field: "lease")
        }
        let timestamp = now.timeIntervalSince1970
        return try await database.write { db in
            guard var command = try RelayV2CommandRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM relay_v2_commands
                    WHERE account_id=?
                      AND (state IN ('queued','sending','retry_wait')
                           OR (state='ambiguous' AND next_attempt_at IS NOT NULL))
                      AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                      AND (lease_expires_at IS NULL OR lease_expires_at <= ?)
                    ORDER BY created_at, rowid LIMIT 1
                    """,
                arguments: [accountID, timestamp, timestamp]
            ) else { return nil }
            command.state = .sending
            command.attemptCount += 1
            command.leaseOwner = owner
            command.leaseExpiresAt = timestamp + leaseDuration
            command.updatedAt = timestamp
            try command.update(db)
            return command
        }
    }

    @discardableResult
    func markRelayV2Command(
        operationID: String,
        state: RelayV2CommandState,
        errorCode: RelayV2ErrorCode? = nil,
        retryAt: Date? = nil,
        onlyIfCurrentState expectedState: RelayV2CommandState? = nil,
        now: Date = Date()
    ) async throws -> Bool {
        let timestamp = now.timeIntervalSince1970
        let changed = try await database.write { db -> Int in
            try db.execute(
                sql: """
                    UPDATE relay_v2_commands SET
                        state=?, next_attempt_at=?, last_error_code=?,
                        lease_owner=NULL, lease_expires_at=NULL, updated_at=?,
                        completed_at=CASE WHEN ?='completed' THEN ? ELSE completed_at END
                    WHERE op_id=? AND (? IS NULL OR state=?)
                    """,
                arguments: [
                    state.rawValue, retryAt?.timeIntervalSince1970, errorCode?.rawValue,
                    timestamp, state.rawValue, timestamp, operationID,
                    expectedState?.rawValue, expectedState?.rawValue,
                ]
            )
            return db.changesCount
        }
        if expectedState != nil { return changed == 1 }
        guard changed == 1 else { throw RelayV2ProtocolError.conflict("Relay operation not found") }
        return true
    }

    func relayV2Commands(accountID: String) async throws -> [RelayV2CommandRecord] {
        try await database.read { db in
            try RelayV2CommandRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM relay_v2_commands
                    WHERE account_id=? ORDER BY created_at,rowid
                    """,
                arguments: [accountID]
            )
        }
    }

    func relayV2Command(
        accountID: String,
        clientMessageID: String
    ) async throws -> RelayV2CommandRecord? {
        try await database.read { db in
            try RelayV2CommandRecord.fetchOne(
                db,
                sql: "SELECT * FROM relay_v2_commands WHERE account_id=? AND client_message_id=?",
                arguments: [accountID, clientMessageID]
            )
        }
    }

    func persistRelayV2Envelope(
        operationID: String,
        envelope: RelayV2OuterEnvelope
    ) async throws -> RelayV2OuterEnvelope {
        let encoded = try envelope.canonicalJSON()
        return try await database.write { db in
            guard var command = try RelayV2CommandRecord.fetchOne(db, key: operationID) else {
                throw RelayV2ProtocolError.conflict("Relay operation not found")
            }
            if let existing = command.envelopeJSON {
                return try RelayV2OuterEnvelope.decodeStrict(from: existing)
            }
            command.envelopeJSON = encoded
            command.updatedAt = Date().timeIntervalSince1970
            try command.update(db)
            return envelope
        }
    }

    func resolveRelayV2Command(
        accountID: String,
        clientMessageID: String,
        errorCode: RelayV2ErrorCode? = nil,
        now: Date = Date()
    ) async throws {
        let state: RelayV2CommandState
        let retry: Double?
        switch errorCode {
        case nil:
            state = .completed
            retry = nil
        case .gatewayAmbiguous:
            state = .ambiguous
            // An authenticated RPC response is final for its op_id/MID. Keep
            // the uncertainty visible, but do not replay an operation the Agent
            // has already cached as failed.
            retry = nil
        case .gatewayOffline, .rateLimited, .mailboxFull, .internal:
            // These are retryable only as a NEW user operation. Replaying this
            // persisted envelope cannot succeed: the MID is seen and op_id is
            // already terminal in the Agent ledger.
            state = .completed
            retry = nil
        case .expired:
            state = .expired
            retry = nil
        case .invalidArgument, .unauthenticated, .revoked, .unsupportedVersion,
             .notFound, .conflict, .alreadyResolved:
            state = .completed
            retry = nil
        }
        let changed = try await database.write { db -> Int in
            try db.execute(
                sql: """
                    UPDATE relay_v2_commands SET state=?,last_error_code=?,next_attempt_at=?,
                    lease_owner=NULL,lease_expires_at=NULL,updated_at=?,completed_at=?
                    WHERE account_id=? AND client_message_id=? AND state IN ('accepted','sending','ambiguous')
                    """,
                arguments: [state.rawValue, errorCode?.rawValue, retry, now.timeIntervalSince1970,
                            (state == .completed || state == .expired || (state == .ambiguous && retry == nil))
                                ? now.timeIntervalSince1970 : nil,
                            accountID, clientMessageID]
            )
            return db.changesCount
        }
        guard changed <= 1 else { throw RelayV2ProtocolError.conflict("Duplicate client message ID") }
    }
}

enum RelayV2NotificationActionQueue {
    static func enqueueApproval(
        accountID: String,
        sessionID: String,
        requestID: String,
        approve: Bool,
        capability: String,
        allowedDecisions: [String],
        deviceID: String?,
        deviceKeyGeneration: UInt32?,
        operationID: String?,
        clientMessageID: String?
    ) async throws {
        let decision = approve ? "approve_once" : "deny"
        let permitted = Set(allowedDecisions)
        guard RelayV2Wire.isToken(capability), !capability.isEmpty,
              !permitted.isEmpty,
              permitted.isSubset(of: ["approve_once", "deny"]),
              permitted.contains(decision),
              deviceID.map(RelayV2Wire.isToken) ?? true,
              deviceKeyGeneration.map({ $0 > 0 }) ?? true else {
            throw RelayV2ProtocolError.unauthenticated
        }
        let stableDigest = SHA256.hash(
            data: Data("\(accountID)|\(sessionID)|\(requestID)|\(capability)".utf8)
        )
        let stableToken = RelayV2Wire.base64URL(Data(stableDigest.prefix(16)))
        let opID = operationID.flatMap { RelayV2Wire.isToken($0) ? $0 : nil }
            ?? "op_\(stableToken)"
        let clientID = clientMessageID.flatMap { RelayV2Wire.isToken($0) ? $0 : nil }
            ?? RelayV2Identifiers.stableCanonicalUUID(seed: Data(stableDigest))
        let repository = try await WorkRepository.openAppGroup(scope: nil)
        var payload: [String: JSONValue] = [
            "request_id": .string(requestID),
            "decision": .string(decision),
            "capability": .string(capability),
            "session_id": .string(sessionID),
        ]
        try await repository.enqueueRelayV2Command(
            operationID: opID,
            clientMessageID: clientID,
            accountID: accountID,
            sessionID: sessionID,
            kind: .approval,
            payload: payload
        )
        NotificationCenter.default.post(name: .relayV2CommandQueued, object: accountID)
    }
}
