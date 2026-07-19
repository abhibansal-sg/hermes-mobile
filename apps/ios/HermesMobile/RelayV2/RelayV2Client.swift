import CryptoKit
import Foundation

actor RelayV2Client {
    static let automaticRotationAgeMilliseconds: UInt64 = 7 * 24 * 60 * 60 * 1_000
    static let automaticRotationMessageLimit: UInt64 = 10_000
    static let maximumMailboxTTLMilliseconds: UInt64 = 24 * 60 * 60 * 1_000
    static let rotationRetryGraceMilliseconds: UInt64 = 24 * 60 * 60 * 1_000
    static let automaticRotationOverlapMilliseconds =
        maximumMailboxTTLMilliseconds + rotationRetryGraceMilliseconds

    enum State: Equatable, Sendable {
        case idle
        case connecting
        case open
        case failed(String)
    }

    private(set) var state: State = .idle
    private var identity: RelayV2Identity
    private let keyStore: RelayV2KeychainStore
    private let database: RelayV2Database
    private let hub: RelayV2HubTransport
    private let workRepository: WorkRepository
    private var connectionLifecycleEpoch: UInt64 = 0
    private var connectionAttemptID: UInt64 = 0
    private var connectionAcceptingAttempts = true
    private var isTerminallyRevoked = false
    private var connectionAttemptTask: Task<Void, Error>?
    private var disconnectInProgress = false
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var receiveTask: Task<Void, Never>?
    private var failureTask: Task<Void, Never>?
    private let onProjection: (@MainActor @Sendable (String, [ChatItem], [RelayV2StoredEvent]) -> Void)?
    private let onTextDeltas: (@MainActor @Sendable (
        String, [RelayV2CommittedTextDelta]
    ) -> Bool)?
    private let onSessionBinding: (@MainActor @Sendable (String, String) -> Void)?
    private let onCommandResolution: (@MainActor @Sendable (
        String, RelayV2CommandKind, RelayV2ErrorCode?
    ) -> Void)?
    private var onTerminalRevocation: (@MainActor @Sendable (String) -> Void)?
    private var pendingRPC: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var commandDrainGeneration: UInt64 = 0
    private var commandDrainLifecycleEpoch: UInt64 = 0
    private var commandDrainTaskID: UInt64 = 0
    private var commandDrainAcceptingWakeups = true
    private var commandDrainTask: Task<Void, Never>?
    private var commandRetryTimerID: UInt64 = 0
    private var commandRetryTimerDeadline: Date?
    private var commandRetryTimerTask: Task<Void, Never>?
    private enum CommandWakeDeadlineDiscovery {
        case loaded(Date?)
        case failed
    }
    #if DEBUG
    private var connectionAfterHubConnectHookForTesting: (@Sendable () async -> Void)?
    private var connectionDidInvalidateHookForTesting: (@Sendable () async -> Void)?
    private var commandDrainEmptyTailHookForTesting: (@Sendable () async -> Void)?
    private var commandDrainBeforeClaimHookForTesting: (@Sendable () async throws -> Void)?
    private var commandDrainSendHookForTesting: (@Sendable (
        RelayV2CommandRecord
    ) async throws -> RelayV2HubAccepted)?
    private var commandWakeDeadlineLoadHookForTesting:
        (@Sendable () async throws -> [RelayV2CommandRecord])?
    private var revocationAfterTombstoneHookForTesting:
        (@Sendable (String) async -> Bool)?
    private var commandDrainIdleWaitersForTesting: [CheckedContinuation<Void, Never>] = []
    #endif

    init(
        identity: RelayV2Identity,
        keyStore: RelayV2KeychainStore,
        database: RelayV2Database,
        hub: RelayV2HubTransport,
        workRepository: WorkRepository,
        onProjection: (@MainActor @Sendable (String, [ChatItem], [RelayV2StoredEvent]) -> Void)? = nil,
        onTextDeltas: (@MainActor @Sendable (
            String, [RelayV2CommittedTextDelta]
        ) -> Bool)? = nil,
        onSessionBinding: (@MainActor @Sendable (String, String) -> Void)? = nil,
        onCommandResolution: (@MainActor @Sendable (
            String, RelayV2CommandKind, RelayV2ErrorCode?
        ) -> Void)? = nil
    ) throws {
        guard identity.routeID != nil,
              identity.agentRouteID != nil,
              identity.currentKeys != nil,
              identity.agentAgreementPublicKey?.count == 32,
              identity.agentSigningPublicKey?.count == 32,
              identity.agentKeyGeneration != nil else {
            throw RelayV2ProtocolError.invalidArgument(field: "paired_identity")
        }
        self.identity = identity
        self.keyStore = keyStore
        self.database = database
        self.hub = hub
        self.workRepository = workRepository
        self.onProjection = onProjection
        self.onTextDeltas = onTextDeltas
        self.onSessionBinding = onSessionBinding
        self.onCommandResolution = onCommandResolution
    }

    /// ConnectionStore installs this after assigning ownership. Awaiting the
    /// main-actor callback makes terminal revocation visible to admission gates
    /// before the failing client operation returns to its caller.
    func setTerminalRevocationHandler(
        _ handler: (@MainActor @Sendable (String) -> Void)?
    ) async {
        onTerminalRevocation = handler
        if isTerminallyRevoked, let handler {
            await handler(identity.accountID)
        }
    }

    func connect() async throws {
        try await requireDurableAccountActive()
        guard connectionAcceptingAttempts else { throw CancellationError() }
        if let connectionAttemptTask {
            return try await connectionAttemptTask.value
        }

        connectionLifecycleEpoch &+= 1
        connectionAttemptID &+= 1
        let epoch = connectionLifecycleEpoch
        let taskID = connectionAttemptID
        state = .connecting
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.runConnectionAttempt(epoch: epoch, taskID: taskID)
        }
        connectionAttemptTask = task
        try await task.value
    }

    private func runConnectionAttempt(epoch: UInt64, taskID: UInt64) async throws {
        defer { finishConnectionAttempt(taskID: taskID) }
        do {
            try requireConnectionAttemptActive(epoch: epoch, taskID: taskID)
            let previousReceiveTask = receiveTask
            let previousFailureTask = failureTask
            receiveTask = nil
            failureTask = nil
            previousReceiveTask?.cancel()
            previousFailureTask?.cancel()
            await previousReceiveTask?.value
            try requireConnectionAttemptActive(epoch: epoch, taskID: taskID)
            await previousFailureTask?.value
            try requireConnectionAttemptActive(epoch: epoch, taskID: taskID)

            do {
                try await hub.connect()
            } catch {
                if Self.isTerminalRevocation(error) {
                    try await persistTerminalRevocation(
                        source: "hub_handshake",
                        messageID: nil
                    )
                    await hub.disconnect()
                    throw RelayV2ProtocolError.revoked
                }
                throw error
            }
            try requireConnectionAttemptActive(epoch: epoch, taskID: taskID)
            #if DEBUG
            await connectionAfterHubConnectHookForTesting?()
            try requireConnectionAttemptActive(epoch: epoch, taskID: taskID)
            #endif
            state = .open
            try await recoverPendingLocalRotation()
            try requireConnectionAttemptActive(epoch: epoch, taskID: taskID)
            try await drainControlOutbox()
            try requireConnectionAttemptActive(epoch: epoch, taskID: taskID)
            try await rotateDeviceKeysIfNeeded()
            try requireConnectionAttemptActive(epoch: epoch, taskID: taskID)
            installConnectionWorkers(epoch: epoch)
            try requireConnectionAttemptActive(epoch: epoch, taskID: taskID)
            resumeCommandDrainLifecycle()
            await drainCommands(repository: workRepository)
            try requireConnectionAttemptActive(epoch: epoch, taskID: taskID)
        } catch {
            if isConnectionAttemptActive(epoch: epoch, taskID: taskID) {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func disconnect() async {
        if disconnectInProgress {
            await withCheckedContinuation { disconnectWaiters.append($0) }
            return
        }
        disconnectInProgress = true
        connectionAcceptingAttempts = false
        connectionLifecycleEpoch &+= 1
        let disconnectEpoch = connectionLifecycleEpoch
        let attemptTask = connectionAttemptTask
        let activeReceiveTask = receiveTask
        let activeFailureTask = failureTask
        connectionAttemptTask = nil
        receiveTask = nil
        failureTask = nil
        attemptTask?.cancel()
        activeReceiveTask?.cancel()
        activeFailureTask?.cancel()
        #if DEBUG
        await connectionDidInvalidateHookForTesting?()
        #endif
        await stopCommandDrainLifecycle()
        _ = await attemptTask?.result
        await activeReceiveTask?.value
        await activeFailureTask?.value
        await hub.disconnect()
        let waiters = pendingRPC.values
        pendingRPC.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: RelayV2ProtocolError.transport("Relay disconnected"))
        }
        if disconnectEpoch == connectionLifecycleEpoch {
            if isTerminallyRevoked {
                state = .failed(RelayV2ProtocolError.revoked.localizedDescription)
                connectionAcceptingAttempts = false
            } else {
                state = .idle
                connectionAcceptingAttempts = true
            }
        }
        disconnectInProgress = false
        let completedDisconnectWaiters = disconnectWaiters
        disconnectWaiters.removeAll()
        completedDisconnectWaiters.forEach { $0.resume() }
    }

    private func installConnectionWorkers(epoch: UInt64) {
        let messages = hub.messages
        receiveTask = Task { [weak self] in
            for await envelope in messages {
                guard !Task.isCancelled, let self else { return }
                guard await self.isConnectionEpochActive(epoch) else { return }
                do {
                    try await self.ingest(envelope)
                } catch {
                    // Retry remains in the Hub mailbox.
                }
                guard await self.isConnectionEpochActive(epoch) else { return }
            }
        }

        let failures = hub.failures
        failureTask = Task { [weak self] in
            var attempt = 0
            for await failure in failures {
                guard !Task.isCancelled, let self else { return }
                guard await self.isConnectionEpochActive(epoch) else { return }
                if Self.isTerminalRevocation(failure) {
                    do {
                        try await self.persistTerminalRevocation(
                            source: "hub_socket",
                            messageID: nil
                        )
                    } catch {
                        await self.recordTransportFailure(
                            error.localizedDescription,
                            epoch: epoch
                        )
                    }
                    await self.hub.disconnect()
                    return
                }
                await self.recordTransportFailure(failure.localizedDescription, epoch: epoch)
                attempt += 1
                let delay = min(30.0, pow(2.0, Double(min(attempt - 1, 5))))
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                guard await self.isConnectionEpochActive(epoch) else { return }
                do {
                    try await self.reconnectTransport(epoch: epoch)
                    try await self.drainControlOutbox()
                    guard await self.isConnectionEpochActive(epoch) else { return }
                    await self.drainCommands(repository: self.workRepository)
                    guard await self.isConnectionEpochActive(epoch) else { return }
                } catch is CancellationError {
                    return
                } catch {
                    await self.recordTransportFailure(
                        error.localizedDescription,
                        epoch: epoch
                    )
                }
            }
        }
    }

    private func isConnectionEpochActive(_ epoch: UInt64) -> Bool {
        connectionAcceptingAttempts && epoch == connectionLifecycleEpoch
    }

    private func isConnectionAttemptActive(epoch: UInt64, taskID: UInt64) -> Bool {
        isConnectionEpochActive(epoch) && taskID == connectionAttemptID
    }

    private func requireConnectionEpochActive(_ epoch: UInt64) throws {
        guard !Task.isCancelled, isConnectionEpochActive(epoch) else {
            throw CancellationError()
        }
    }

    private func requireConnectionAttemptActive(epoch: UInt64, taskID: UInt64) throws {
        try requireConnectionEpochActive(epoch)
        guard taskID == connectionAttemptID else { throw CancellationError() }
    }

    private func finishConnectionAttempt(taskID: UInt64) {
        guard taskID == connectionAttemptID else { return }
        connectionAttemptTask = nil
    }

    private func recordTransportFailure(_ message: String, epoch: UInt64) {
        guard isConnectionEpochActive(epoch) else { return }
        state = .failed(message)
    }

    private func reconnectTransport(epoch: UInt64) async throws {
        try requireConnectionEpochActive(epoch)
        try await requireDurableAccountActive()
        state = .connecting
        do {
            try await hub.connect()
        } catch {
            if Self.isTerminalRevocation(error) {
                try await persistTerminalRevocation(source: "hub_reconnect", messageID: nil)
                await hub.disconnect()
                throw RelayV2ProtocolError.revoked
            }
            throw error
        }
        try requireConnectionEpochActive(epoch)
        state = .open
    }

    func ingest(_ envelope: RelayV2OuterEnvelope) async throws {
        try await requireDurableAccountActive()
        guard let deviceRouteID = identity.routeID,
              let agentRouteID = identity.agentRouteID,
              let agentSigningKey = identity.agentSigningPublicKey,
              identity.agentKeyGeneration != nil else {
            throw RelayV2ProtocolError.revoked
        }
        let alreadySeen = try await database.hasSeen(
            accountID: identity.accountID,
            messageID: envelope.header.messageID
        )
        if alreadySeen {
            try await drainControlOutbox()
            try await hub.acknowledge([envelope.header.messageID])
            return
        }
        let purpose: RelayV2HPKEPurpose
        switch envelope.header.messageClass {
        case .realtime, .state: purpose = .chat
        case .command, .control: purpose = .control
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let receive = RelayV2ReceiveContext(
            expectedDestination: deviceRouteID,
            expectedSource: agentRouteID,
            nowMilliseconds: now,
            seenMessageIDs: alreadySeen ? [envelope.header.messageID] : []
        )
        var recipientPrivateKeys = identity.recipientPrivateKeys
        if recipientPrivateKeys[envelope.header.recipientKeyGeneration] == nil,
           let pending = try keyStore.loadPendingLocalRotation(accountID: identity.accountID),
           let preparedIdentity = pending.updatedIdentity {
            // The Agent applies a device KEM rotation before acknowledging it.
            // Accept that authenticated acknowledgement with the prepared key,
            // but do not make the generation current until the receipt arrives.
            recipientPrivateKeys.merge(preparedIdentity.recipientPrivateKeys) { current, _ in current }
        }
        var opened: RelayV2SecureMessage?
        for remoteKey in identity.activeAgentAgreementKeys(nowMilliseconds: now) {
            if let candidate = try? RelayV2Crypto.openAuthenticatedEnvelope(
                envelope,
                recipientPrivateKeys: recipientPrivateKeys,
                senderAgreementPublicKey: remoteKey.publicKey,
                senderSigningPublicKey: agentSigningKey,
                expectedSenderKeyGeneration: remoteKey.generation,
                purpose: purpose,
                direction: .agentToDevice,
                receive: receive
            ) {
                opened = candidate
                break
            }
        }
        guard let message = opened else { throw RelayV2ProtocolError.unauthenticated }

        let compatible: Bool
        switch envelope.header.messageClass {
        case .realtime:
            compatible = message.kind == .frameBatch
        case .state:
            compatible = message.kind == .frameBatch || message.kind == .checkpoint
        case .control:
            compatible = [.rpcResponse, .keyRotate, .deviceRevoke, .deliveryReceipt]
                .contains(message.kind)
        case .command:
            compatible = false
        }
        guard compatible else {
            throw RelayV2ProtocolError.invalidArgument(field: "message_class_kind")
        }
        try validateInboundBody(message)

        switch message.kind {
        case .frameBatch:
            let body = try RelayV2Wire.canonicalJSON(message.body)
            let batch = try JSONDecoder().decode(RelayV2FrameBatch.self, from: body)
            let (through, overflow) = batch.firstSequence.addingReportingOverflow(
                Int64(batch.frames.count - 1)
            )
            guard !overflow else {
                throw RelayV2ProtocolError.invalidArgument(field: "frame_batch.first_seq")
            }
            let stream = try await database.streamState(
                accountID: identity.accountID,
                streamID: batch.streamID
            )
            let currentThrough = stream?.throughSequence ?? 0
            let (expectedSequence, expectedOverflow) = currentThrough.addingReportingOverflow(1)
            guard !expectedOverflow else {
                throw RelayV2ProtocolError.invalidArgument(field: "stream.through_seq")
            }
            if Self.requiresSync(batch: batch, currentThrough: currentThrough) {
                try await requestSync(
                    sessionID: batch.frames[0].sessionID,
                    streamID: batch.streamID,
                    lastSequence: currentThrough
                )
                throw RelayV2ProtocolError.conflict(
                    "Relay stream gap: expected \(expectedSequence), received \(batch.firstSequence)"
                )
            }
            let stableKey = "\(batch.streamID):\(through)"
            let streamAck = try makeControlEnvelope(
                kind: .streamAck,
                stableKey: "stream_ack:\(stableKey)",
                body: ["stream_id": .string(batch.streamID), "through_seq": .number(Double(through))]
            )
            let applyResult = try await database.apply(
                accountID: identity.accountID,
                messageID: message.messageID,
                batch: batch,
                receivedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                outboundControlEnvelope: streamAck,
                outboundStableKey: stableKey
            )
            try await publishProjection(
                for: batch,
                throughSequence: through,
                committedTextDeltas: applyResult.committedTextDeltas
            )
            try await drainControlOutbox()
            try await hub.acknowledge([message.messageID])
        case .checkpoint:
            guard let streamID = message.body["stream_id"]?.stringValue,
                  let through = message.body["through_seq"]?.intValue else {
                throw RelayV2ProtocolError.invalidArgument(field: "checkpoint")
            }
            let stableKey = "\(streamID):\(through)"
            let streamAck = try makeControlEnvelope(
                kind: .streamAck,
                stableKey: "stream_ack:\(stableKey)",
                body: ["stream_id": .string(streamID), "through_seq": .number(Double(through))]
            )
            try await database.applyCheckpoint(
                accountID: identity.accountID, messageID: message.messageID, body: message.body,
                receivedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                outboundControlEnvelope: streamAck,
                outboundStableKey: stableKey
            )
            if let sessionID = message.body["session_id"]?.stringValue {
                let projection = try await database.projectionItems(
                    accountID: identity.accountID, incomingSessionID: sessionID
                )
                await onProjection?(
                    projection.originSessionID, projection.items.map(\.chatItem), []
                )
            }
            try await drainControlOutbox()
            try await hub.acknowledge([message.messageID])
        case .rpcResponse:
            try await applyReceipt(message)
            let delivery = try makeControlEnvelope(
                kind: .deliveryReceipt,
                stableKey: "delivery_receipt:\(message.messageID)",
                body: ["mid": .string(message.messageID)]
            )
            try await database.recordSeenAndQueueControl(
                accountID: identity.accountID, messageID: message.messageID, envelope: delivery,
                kind: "delivery_receipt", stableKey: message.messageID,
                receivedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            try await drainControlOutbox()
            try await hub.acknowledge([message.messageID])
        case .keyRotate:
            try applyKeyRotation(message, nowMilliseconds: now)
            let delivery = try makeControlEnvelope(
                kind: .deliveryReceipt,
                stableKey: "delivery_receipt:\(message.messageID)",
                body: ["mid": .string(message.messageID)]
            )
            try await database.recordSeenAndQueueControl(
                accountID: identity.accountID, messageID: message.messageID, envelope: delivery,
                kind: "delivery_receipt", stableKey: message.messageID,
                receivedAtMilliseconds: Int64(now)
            )
            try await drainControlOutbox()
            try await hub.acknowledge([message.messageID])
        case .deviceRevoke:
            // The account tombstone is the first durable effect. A crash after
            // this write can replay neither the message nor the credential; no
            // seen marker, delivery receipt, or Hub ACK may precede it.
            try await persistTerminalRevocation(
                source: "device_revoke",
                messageID: message.messageID
            )
            await hub.disconnect()
            throw RelayV2ProtocolError.revoked
        case .deliveryReceipt:
            let completedPurpose = try applyLocalRotationReceipt(message)
            try await database.recordSeen(
                accountID: identity.accountID,
                messageID: message.messageID,
                receivedAtMilliseconds: Int64(now)
            )
            try await hub.acknowledge([message.messageID])
            if completedPurpose == "preview" {
                try? await refreshRotatedPreviewRegistration()
            } else if completedPurpose == "kem" {
                // Preview keys are a separate causal rotation. Start it only
                // after the Agent proves it has installed the chat KEM.
                try await rotateDeviceKeysIfNeeded()
            }
        case .pairInit, .pairAccept, .pairConfirm, .rpcRequest, .syncRequest,
             .streamAck:
            throw RelayV2ProtocolError.conflict("Unsupported Agent-to-device message kind")
        }
    }

    func validateInboundBody(_ message: RelayV2SecureMessage) throws {
        switch message.kind {
        case .frameBatch:
            guard Set(message.body.keys) == ["stream_id", "first_seq", "frames"],
                  let streamID = message.body["stream_id"]?.stringValue,
                  RelayV2Wire.isToken(streamID),
                  let firstSequence = Self.integer(
                    message.body["first_seq"], minimum: 1,
                    maximum: RelayV2.maximumJSONIntegerInt64
                  ),
                  let frames = message.body["frames"]?.arrayValue,
                  (1...1_024).contains(frames.count),
                  firstSequence <= RelayV2.maximumJSONIntegerInt64 - Int64(frames.count - 1) else {
                throw RelayV2ProtocolError.invalidArgument(field: "frame_batch")
            }
            for frameValue in frames {
                guard let frame = frameValue.objectValue,
                      Set(frame.keys) == ["sid", "turn", "kind", "body"],
                      let sessionID = frame["sid"]?.stringValue,
                      RelayV2Wire.isToken(sessionID),
                      Self.isTokenOrNull(frame["turn"]),
                      let kind = frame["kind"]?.stringValue,
                      let body = frame["body"]?.objectValue else {
                    throw RelayV2ProtocolError.invalidArgument(field: "frame")
                }
                try Self.validateFrameBody(kind: kind, body: body)
            }
        case .checkpoint:
            try Self.validateCheckpointBody(message.body)
        case .rpcResponse:
            let keys = Set(message.body.keys)
            guard (keys == ["jsonrpc", "id", "result"]
                    || keys == ["jsonrpc", "id", "error"]),
                  message.body["jsonrpc"]?.stringValue == "2.0",
                  let requestID = message.body["id"]?.stringValue,
                  RelayV2Wire.isToken(requestID) else {
                throw RelayV2ProtocolError.invalidArgument(field: "rpc_response")
            }
            if keys.contains("result"), message.body["result"]?.objectValue == nil {
                throw RelayV2ProtocolError.invalidArgument(field: "rpc_response.result")
            }
            if let error = message.body["error"]?.objectValue {
                let errorKeys = Set(error.keys)
                guard errorKeys == ["code", "message"] || errorKeys == ["code", "message", "details"],
                      let rawCode = error["code"]?.stringValue,
                      RelayV2ErrorCode(rawValue: rawCode) != nil,
                      let errorMessage = error["message"]?.stringValue,
                      (1...512).contains(errorMessage.unicodeScalars.count),
                      error["details"].map({ $0.objectValue != nil }) ?? true else {
                    throw RelayV2ProtocolError.invalidArgument(field: "rpc_response.error")
                }
            }
        case .deviceRevoke:
            guard Set(message.body.keys) == ["device_id"],
                  message.body["device_id"]?.stringValue == identity.deviceID else {
                throw RelayV2ProtocolError.unauthenticated
            }
        case .keyRotate:
            guard Set(message.body.keys) == ["purpose", "generation", "public_key", "previous_not_after_ms"],
                  ["kem", "preview"].contains(message.body["purpose"]?.stringValue ?? ""),
                  Self.integer(
                    message.body["generation"], minimum: 1, maximum: Int64(UInt32.max)
                  ) != nil,
                  Self.integer(
                    message.body["previous_not_after_ms"], minimum: 0,
                    maximum: RelayV2.maximumJSONIntegerInt64
                  ) != nil,
                  let publicKey = message.body["public_key"]?.stringValue,
                  (try? RelayV2Wire.decodeBase64URL(publicKey, exactBytes: 32)) != nil else {
                throw RelayV2ProtocolError.invalidArgument(field: "key_rotate")
            }
        case .deliveryReceipt:
            guard Set(message.body.keys) == ["mid"],
                  let messageID = message.body["mid"]?.stringValue,
                  (try? RelayV2Wire.decodeBase64URL(messageID, exactBytes: 16)) != nil else {
                throw RelayV2ProtocolError.invalidArgument(field: "delivery_receipt")
            }
        case .pairInit, .pairAccept, .pairConfirm, .rpcRequest, .streamAck,
             .syncRequest:
            break
        }
    }

    private static func validateFrameBody(kind: String, body: [String: JSONValue]) throws {
        switch kind {
        case "item.started", "item.completed":
            try validateFullItem(body, field: "item")
        case "item.delta":
            guard Set(body.keys) == ["item_id", "from_rev", "to_rev", "ops"],
                  let itemID = body["item_id"]?.stringValue,
                  RelayV2Wire.isToken(itemID),
                  Self.integer(
                    body["from_rev"], minimum: 1,
                    maximum: RelayV2.maximumJSONIntegerInt64
                  ) != nil,
                  Self.integer(
                    body["to_rev"], minimum: 2,
                    maximum: RelayV2.maximumJSONIntegerInt64
                  ) != nil,
                  let operations = body["ops"]?.arrayValue,
                  operations.count == 1 else {
                throw RelayV2ProtocolError.invalidArgument(field: "item_delta")
            }
            for operation in operations {
                guard let object = operation.objectValue,
                      Set(object.keys) == ["op", "path", "offset", "data"],
                      object["op"]?.stringValue == "append_utf8",
                      object["path"]?.stringValue == "/body/text",
                      Self.integer(object["offset"], minimum: 0, maximum: 10_485_760) != nil,
                      let data = object["data"]?.stringValue,
                      data.unicodeScalars.count <= 262_144 else {
                    throw RelayV2ProtocolError.invalidArgument(field: "item_delta.ops")
                }
            }
        case "checkpoint":
            try validateCheckpointBody(body)
        case "turn.started", "turn.completed", "approval.request", "clarify.request",
             "status", "title", "snapshot":
            // The checked-in HRP/2 schema deliberately leaves these evolving
            // frame bodies as open JSON objects. Still validate the complete
            // object before WAL admission: numeric scalars must be canonical,
            // lossless wire integers and the canonical body must fit within the
            // protocol's maximum encrypted-message budget.
            try validateOpenFrameBody(body, field: "frame.\(kind).body")
        default:
            throw RelayV2ProtocolError.invalidArgument(field: "frame.kind")
        }
    }

    private static func validateOpenFrameBody(
        _ body: [String: JSONValue],
        field: String
    ) throws {
        guard RelayV2Wire.containsOnlyCanonicalIntegerNumbers(.object(body)),
              let encoded = try? RelayV2Wire.canonicalJSON(body),
              encoded.count <= 262_144 else {
            throw RelayV2ProtocolError.invalidArgument(field: field)
        }
    }

    private static func validateCheckpointBody(_ body: [String: JSONValue]) throws {
        guard Set(body.keys) == ["stream_id", "through_seq", "session_id", "snapshot_revision",
                                 "replace", "items", "tombstones"],
              let streamID = body["stream_id"]?.stringValue,
              RelayV2Wire.isToken(streamID),
              let sessionID = body["session_id"]?.stringValue,
              RelayV2Wire.isToken(sessionID),
              integer(
                body["through_seq"], minimum: 0,
                maximum: RelayV2.maximumJSONIntegerInt64
              ) != nil,
              integer(
                body["snapshot_revision"], minimum: 0,
                maximum: RelayV2.maximumJSONIntegerInt64
              ) != nil,
              body["replace"]?.boolValue != nil,
              let items = body["items"]?.arrayValue,
              items.count <= 10_000,
              let tombstones = body["tombstones"]?.arrayValue,
              tombstones.count <= 10_000 else {
            throw RelayV2ProtocolError.invalidArgument(field: "checkpoint")
        }
        for item in items {
            guard let object = item.objectValue else {
                throw RelayV2ProtocolError.invalidArgument(field: "checkpoint.items")
            }
            try validateFullItem(object, field: "checkpoint.items")
        }
        for tombstone in tombstones {
            guard let object = tombstone.objectValue,
                  Set(object.keys) == ["item_id", "deleted_at_revision"],
                  let itemID = object["item_id"]?.stringValue,
                  RelayV2Wire.isToken(itemID),
                  integer(
                    object["deleted_at_revision"], minimum: 1,
                    maximum: RelayV2.maximumJSONIntegerInt64
                  ) != nil else {
                throw RelayV2ProtocolError.invalidArgument(field: "checkpoint.tombstones")
            }
        }
    }

    private static func validateFullItem(
        _ body: [String: JSONValue],
        field: String
    ) throws {
        guard Set(body.keys) == ["item_id", "session_id", "turn_id", "type", "status",
                                 "ord", "rev", "summary", "body"],
              let itemID = body["item_id"]?.stringValue,
              RelayV2Wire.isToken(itemID),
              let sessionID = body["session_id"]?.stringValue,
              RelayV2Wire.isToken(sessionID),
              isTokenOrNull(body["turn_id"]),
              let type = body["type"]?.stringValue,
              (1...128).contains(type.unicodeScalars.count),
              let status = body["status"]?.stringValue,
              ["in_progress", "completed", "failed"].contains(status),
              integer(body["ord"], minimum: 0, maximum: 2_147_483_647) != nil,
              integer(
                body["rev"], minimum: 1,
                maximum: RelayV2.maximumJSONIntegerInt64
              ) != nil,
              let summary = body["summary"]?.stringValue,
              summary.unicodeScalars.count <= 2_000,
              body["body"]?.objectValue != nil else {
            throw RelayV2ProtocolError.invalidArgument(field: field)
        }
    }

    private static func isTokenOrNull(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        if value.isNull { return true }
        return value.stringValue.map(RelayV2Wire.isToken) ?? false
    }

    private static func integer(
        _ value: JSONValue?,
        minimum: Int64,
        maximum: Int64
    ) -> Int64? {
        guard let number = value?.doubleValue,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= -RelayV2.maximumExactlyRepresentableJSONInteger,
              number <= RelayV2.maximumExactlyRepresentableJSONInteger else { return nil }
        let integer = Int64(number)
        guard integer >= minimum, integer <= maximum else { return nil }
        return integer
    }

    private func makeControlEnvelope(
        kind: RelayV2SecureMessageKind,
        stableKey: String,
        body: [String: JSONValue]
    ) throws -> RelayV2OuterEnvelope {
        guard let source = identity.routeID,
              let destination = identity.agentRouteID,
              let recipientKey = identity.agentAgreementPublicKey,
              let recipientGeneration = identity.agentKeyGeneration,
              let keys = identity.currentKeys else {
            throw RelayV2ProtocolError.revoked
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let expiry = now + 24 * 60 * 60 * 1_000
        let mid = RelayV2Wire.base64URL(Data(SHA256.hash(data: Data(stableKey.utf8))).prefix(16))
        let message = try RelayV2SecureMessage(
            messageID: mid, kind: kind, senderKeyGeneration: keys.generation,
            createdAtMilliseconds: now, expiresAtMilliseconds: expiry, body: body
        )
        let header = try RelayV2OuterHeader(
            source: source, destination: destination, messageID: mid,
            messageClass: .control, expiresAtMilliseconds: expiry,
            recipientKeyGeneration: recipientGeneration
        )
        let envelope = try RelayV2Crypto.sealAuthenticatedEnvelope(
            header: header, message: message, recipientPublicKey: recipientKey,
            senderAgreementPrivateKey: keys.agreementPrivateKey,
            senderSigningPrivateKey: keys.signingPrivateKey,
            purpose: .control, direction: .deviceToAgent
        )
        try recordOutboundEncryption()
        return envelope
    }

    func drainControlOutbox() async throws {
        try await requireDurableAccountActive()
        for record in try await database.pendingControl(accountID: identity.accountID) {
            var envelope = try RelayV2OuterEnvelope.decodeStrict(from: record.envelopeJSON)
            let now = UInt64(Date().timeIntervalSince1970 * 1_000)
            if envelope.header.expiresAtMilliseconds <= now {
                let body: [String: JSONValue]
                let kind: RelayV2SecureMessageKind
                switch record.controlKind {
                case "stream_ack":
                    guard let split = record.stableKey.lastIndex(of: ":"),
                          let through = Int64(record.stableKey[record.stableKey.index(after: split)...]) else {
                        try await database.removeControl(
                            accountID: record.accountID, kind: record.controlKind,
                            stableKey: record.stableKey
                        )
                        continue
                    }
                    kind = .streamAck
                    body = [
                        "stream_id": .string(String(record.stableKey[..<split])),
                        "through_seq": .number(Double(through)),
                    ]
                case "delivery_receipt":
                    kind = .deliveryReceipt
                    body = ["mid": .string(record.stableKey)]
                case "sync_request":
                    // A newer observed gap will queue a fresh sync request.
                    try await database.removeControl(
                        accountID: record.accountID, kind: record.controlKind,
                        stableKey: record.stableKey
                    )
                    continue
                case "key_rotate":
                    guard let pending = try keyStore.loadPendingLocalRotation(
                        accountID: identity.accountID
                    ), pending.purpose == record.stableKey.split(separator: ":").first.map(String.init),
                       String(pending.generation) == record.stableKey.split(separator: ":").last.map(String.init)
                    else {
                        try await database.removeControl(
                            accountID: record.accountID, kind: record.controlKind,
                            stableKey: record.stableKey
                        )
                        continue
                    }
                    envelope = try makePendingRotationEnvelope(pending, nowMilliseconds: now)
                    let renewed = RelayV2PendingLocalRotation(
                        accountID: pending.accountID,
                        purpose: pending.purpose,
                        generation: pending.generation,
                        previousNotAfterMilliseconds: pending.previousNotAfterMilliseconds,
                        envelope: envelope,
                        updatedIdentity: pending.updatedIdentity,
                        updatedPreview: pending.updatedPreview
                    )
                    try keyStore.savePendingLocalRotation(renewed)
                    try await database.replaceControl(
                        accountID: record.accountID, kind: record.controlKind,
                        stableKey: record.stableKey, envelope: envelope,
                        nowMilliseconds: Int64(now)
                    )
                    // The renewal was already persisted using the old device KEM
                    // generation. Do not rebuild it with the current generation.
                    kind = .keyRotate
                    body = [:]
                default:
                    try await database.removeControl(
                        accountID: record.accountID, kind: record.controlKind,
                        stableKey: record.stableKey
                    )
                    continue
                }
                if record.controlKind != "key_rotate" {
                    envelope = try makeControlEnvelope(
                        kind: kind,
                        stableKey: "\(record.controlKind):\(record.stableKey):renew:\(now)",
                        body: body
                    )
                    try await database.replaceControl(
                        accountID: record.accountID, kind: record.controlKind,
                        stableKey: record.stableKey, envelope: envelope,
                        nowMilliseconds: Int64(now)
                    )
                }
            }
            try await requireDurableAccountActive()
            let accepted = try await hub.post(envelope)
            guard accepted.accepted && (accepted.stored || accepted.deduplicated) else {
                throw RelayV2ProtocolError.remote(.gatewayAmbiguous, retryAfterSeconds: 30)
            }
            try await database.removeControl(
                accountID: record.accountID, kind: record.controlKind, stableKey: record.stableKey
            )
        }
    }

    private func requestSync(sessionID: String, streamID: String, lastSequence: Int64) async throws {
        let stableKey = "\(sessionID):\(streamID):\(lastSequence)"
        let envelope = try makeControlEnvelope(
            kind: .syncRequest,
            stableKey: "sync_request:\(stableKey)",
            body: [
                "session_id": .string(sessionID),
                "stream_id": .string(streamID),
                "last_seq": .number(Double(lastSequence)),
            ]
        )
        try await database.replaceControl(
            accountID: identity.accountID,
            kind: "sync_request",
            stableKey: stableKey,
            envelope: envelope,
            nowMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        try await drainControlOutbox()
    }

    private static func containsHealingCheckpoint(
        _ batch: RelayV2FrameBatch,
        currentThrough: Int64
    ) -> Bool {
        for (offset, frame) in batch.frames.enumerated() where frame.kind == "checkpoint" {
            let (sequence, overflow) = batch.firstSequence.addingReportingOverflow(Int64(offset))
            guard !overflow,
                  let body = frame.body.objectValue,
                  let through = body["through_seq"]?.intValue,
                  through >= currentThrough,
                  through == sequence - 1 else { continue }
            return true
        }
        return false
    }

    static func requiresSync(batch: RelayV2FrameBatch, currentThrough: Int64?) -> Bool {
        let through = currentThrough ?? 0
        let (expected, overflow) = through.addingReportingOverflow(1)
        guard !overflow, batch.firstSequence > expected else { return false }
        return !containsHealingCheckpoint(batch, currentThrough: through)
    }

    func publishProjection(
        for batch: RelayV2FrameBatch,
        throughSequence: Int64,
        committedTextDeltas: [RelayV2CommittedTextDelta]? = nil
    ) async throws {
        guard onProjection != nil || onTextDeltas != nil else { return }

        // A delta-only commit changes no item metadata and carries no control UI
        // event. Deliver just the affected parts. If the active transcript does
        // not contain one of them (for example after a cold foreground), fall
        // back to the authoritative projection once for that session.
        if batch.frames.allSatisfy({ $0.kind == "item.delta" }),
           let committedTextDeltas,
           let onTextDeltas {
            var orderedSessions: [String] = []
            var bySession: [String: [RelayV2CommittedTextDelta]] = [:]
            for delta in committedTextDeltas {
                if bySession[delta.sessionID] == nil { orderedSessions.append(delta.sessionID) }
                bySession[delta.sessionID, default: []].append(delta)
            }
            for sessionID in orderedSessions {
                guard let deltas = bySession[sessionID] else { continue }
                let origin = try await database.originSessionID(
                    accountID: identity.accountID,
                    liveSessionID: sessionID
                ) ?? sessionID
                let applied = await onTextDeltas(origin, deltas)
                if !applied, let onProjection {
                    let projection = try await database.projectionItems(
                        accountID: identity.accountID,
                        incomingSessionID: sessionID
                    )
                    await onProjection(
                        projection.originSessionID,
                        projection.items.map(\.chatItem),
                        []
                    )
                }
            }
            return
        }

        guard onProjection != nil else { return }
        let storedEvents = try await database.events(
            accountID: identity.accountID,
            streamID: batch.streamID,
            firstSequence: batch.firstSequence,
            throughSequence: throughSequence
        )
        for sessionID in Set(batch.frames.map(\.sessionID)) {
            let projection = try await database.projectionItems(
                accountID: identity.accountID, incomingSessionID: sessionID
            )
            await onProjection?(
                projection.originSessionID,
                projection.items.map(\.chatItem),
                storedEvents.filter { $0.sessionID == sessionID }
            )
        }
    }

    func applyKeyRotation(
        _ message: RelayV2SecureMessage,
        nowMilliseconds: UInt64
    ) throws {
        guard let purpose = message.body["purpose"]?.stringValue,
              let generationValue = message.body["generation"]?.intValue,
              generationValue > 0, generationValue <= Int(UInt32.max),
              let previousNotAfterValue = message.body["previous_not_after_ms"]?.intValue,
              previousNotAfterValue > Int64(nowMilliseconds),
              let encoded = message.body["public_key"]?.stringValue else {
            throw RelayV2ProtocolError.invalidArgument(field: "key_rotate")
        }
        let generation = UInt32(generationValue)
        let previousNotAfter = UInt64(previousNotAfterValue)
        let publicKey = try RelayV2Wire.decodeBase64URL(encoded, exactBytes: 32)
        switch purpose {
        case "kem":
            guard let current = identity.agentKeyGeneration else {
                throw RelayV2ProtocolError.revoked
            }
            if generation == current {
                let previous = identity.agentAgreementKeyGenerations?.first {
                    $0.generation == generation - 1
                }
                guard identity.agentAgreementPublicKey == publicKey,
                      previous?.notAfterMilliseconds == previousNotAfter else {
                    throw RelayV2ProtocolError.conflict("Agent KEM rotation retry changed request")
                }
                return
            }
            guard current < UInt32.max, generation == current + 1 else {
                throw RelayV2ProtocolError.conflict("Agent KEM generation must increase by one")
            }
            var keys = identity.activeAgentAgreementKeys(nowMilliseconds: nowMilliseconds)
                .map { key -> RelayV2RemoteAgreementKey in
                    var previous = key
                    if previous.generation == current {
                        previous.notAfterMilliseconds = previousNotAfter
                    }
                    return previous
                }
            keys.append(.init(generation: generation, publicKey: publicKey, notAfterMilliseconds: nil))
            identity.agentAgreementKeyGenerations = keys
            identity.agentAgreementPublicKey = publicKey
            identity.agentKeyGeneration = generation
            try keyStore.saveIdentity(identity)
        case "preview":
            guard var preview = try keyStore.loadPreviewKey(accountID: identity.accountID) else {
                throw RelayV2ProtocolError.revoked
            }
            let currentAgentGeneration = preview.agentGeneration ?? 1
            if generation == currentAgentGeneration {
                let previous = preview.agentAgreementKeyGenerations?.first {
                    $0.generation == generation - 1
                }
                guard preview.agentAgreementPublicKey == publicKey,
                      previous?.notAfterMilliseconds == previousNotAfter else {
                    throw RelayV2ProtocolError.conflict("Agent preview rotation retry changed request")
                }
                return
            }
            guard currentAgentGeneration < UInt32.max,
                  generation == currentAgentGeneration + 1 else {
                throw RelayV2ProtocolError.conflict("Agent preview generation must increase by one")
            }
            var keys = preview.activeAgentAgreementKeys(nowMilliseconds: nowMilliseconds)
                .map { key -> RelayV2RemoteAgreementKey in
                    var previous = key
                    if previous.generation == currentAgentGeneration {
                        previous.notAfterMilliseconds = previousNotAfter
                    }
                    return previous
                }
            keys.append(.init(generation: generation, publicKey: publicKey, notAfterMilliseconds: nil))
            preview = RelayV2PreviewKeyRecord(
                accountID: preview.accountID,
                privateKey: preview.privateKey,
                agentAgreementPublicKey: publicKey,
                generation: preview.generation,
                agentGeneration: generation,
                agentAgreementKeyGenerations: keys,
                localKeyGenerations: preview.localKeyGenerations
            )
            try keyStore.savePreviewKey(preview)
        default:
            throw RelayV2ProtocolError.invalidArgument(field: "key_rotate.purpose")
        }
    }

    func rotateDeviceKeysIfNeeded(
        maximumAgeMilliseconds: UInt64 = RelayV2Client.automaticRotationAgeMilliseconds,
        maximumEncryptedMessages: UInt64 = RelayV2Client.automaticRotationMessageLimit,
        overlapMilliseconds: UInt64 = RelayV2Client.automaticRotationOverlapMilliseconds
    ) async throws {
        if try keyStore.loadPendingLocalRotation(accountID: identity.accountID) != nil {
            try await recoverPendingLocalRotation()
            return
        }
        guard let current = identity.currentKeys else { throw RelayV2ProtocolError.revoked }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let kemIsDue = now >= current.createdAtMilliseconds
            && now - current.createdAtMilliseconds >= maximumAgeMilliseconds
        let messageLimitIsDue = (identity.outboundEncryptedMessageCount ?? 0)
            >= maximumEncryptedMessages
        if kemIsDue || messageLimitIsDue {
            try await rotateLocalKey(
                purpose: "kem", now: now, overlapMilliseconds: overlapMilliseconds
            )
            return
        }
        guard let preview = try keyStore.loadPreviewKey(accountID: identity.accountID) else { return }
        if kemIsDue || messageLimitIsDue || preview.generation < identity.currentGeneration {
            try await rotateLocalKey(
                purpose: "preview", now: now, overlapMilliseconds: overlapMilliseconds
            )
        }
    }

    private func rotateLocalKey(
        purpose: String,
        now: UInt64,
        overlapMilliseconds: UInt64
    ) async throws {
        guard try keyStore.loadPendingLocalRotation(accountID: identity.accountID) == nil else {
            throw RelayV2ProtocolError.conflict("A device key rotation is already pending")
        }
        let (deadline, overflow) = now.addingReportingOverflow(overlapMilliseconds)
        guard !overflow else { throw RelayV2ProtocolError.invalidArgument(field: "rotation.overlap") }
        let newPair = RelayV2Crypto.generateAgreementKeyPair()
        let generation: UInt32
        var updatedIdentity: RelayV2Identity?
        var updatedPreview: RelayV2PreviewKeyRecord?

        if purpose == "kem" {
            guard let current = identity.currentKeys, current.generation < UInt32.max else {
                throw RelayV2ProtocolError.conflict("Device KEM generation is exhausted")
            }
            generation = current.generation + 1
            var next = identity
            next.keyGenerations = next.keyGenerations.map { value in
                var value = value
                if value.generation == current.generation { value.notAfterMilliseconds = deadline }
                return value
            }
            next.keyGenerations.append(.init(
                generation: generation,
                agreementPrivateKey: newPair.privateKey,
                signingPrivateKey: current.signingPrivateKey,
                createdAtMilliseconds: now
            ))
            next.currentGeneration = generation
            next.outboundEncryptedMessageCount = 0
            updatedIdentity = next
        } else if purpose == "preview" {
            guard let current = try keyStore.loadPreviewKey(accountID: identity.accountID),
                  current.generation < UInt32.max else {
                throw RelayV2ProtocolError.conflict("Preview generation is unavailable")
            }
            generation = current.generation + 1
            var locals = current.activePrivateKeys(nowMilliseconds: now).map { value in
                var value = value
                if value.generation == current.generation { value.notAfterMilliseconds = deadline }
                return value
            }
            locals.append(.init(generation: generation, privateKey: newPair.privateKey, notAfterMilliseconds: nil))
            updatedPreview = .init(
                accountID: current.accountID,
                privateKey: newPair.privateKey,
                agentAgreementPublicKey: current.agentAgreementPublicKey,
                generation: generation,
                agentGeneration: current.agentGeneration,
                agentAgreementKeyGenerations: current.agentAgreementKeyGenerations,
                localKeyGenerations: locals
            )
        } else {
            throw RelayV2ProtocolError.invalidArgument(field: "rotation.purpose")
        }

        let stableKey = "\(purpose):\(generation)"
        let envelope = try makeControlEnvelope(
            kind: .keyRotate,
            stableKey: "key_rotate:\(stableKey)",
            body: [
                "purpose": .string(purpose),
                "generation": .number(Double(generation)),
                "public_key": .string(RelayV2Wire.base64URL(newPair.publicKey)),
                "previous_not_after_ms": .number(Double(deadline)),
            ]
        )
        let pending = RelayV2PendingLocalRotation(
            accountID: identity.accountID,
            purpose: purpose,
            generation: generation,
            previousNotAfterMilliseconds: deadline,
            envelope: envelope,
            updatedIdentity: updatedIdentity,
            updatedPreview: updatedPreview
        )
        try keyStore.savePendingLocalRotation(pending)
        try await database.replaceControl(
            accountID: identity.accountID,
            kind: "key_rotate",
            stableKey: stableKey,
            envelope: envelope,
            nowMilliseconds: Int64(now)
        )
        try await drainControlOutbox()
    }

    func recoverPendingLocalRotation() async throws {
        guard let pending = try keyStore.loadPendingLocalRotation(accountID: identity.accountID) else { return }
        try await database.replaceControl(
            accountID: identity.accountID,
            kind: "key_rotate",
            stableKey: "\(pending.purpose):\(pending.generation)",
            envelope: pending.envelope,
            nowMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        try await drainControlOutbox()
    }

    @discardableResult
    private func applyLocalRotationReceipt(_ message: RelayV2SecureMessage) throws -> String? {
        guard let acknowledgedMessageID = message.body["mid"]?.stringValue else {
            throw RelayV2ProtocolError.invalidArgument(field: "delivery_receipt.mid")
        }
        guard let pending = try keyStore.loadPendingLocalRotation(accountID: identity.accountID),
              pending.envelope.header.messageID == acknowledgedMessageID else {
            // Authenticated receipts can legitimately arrive after a prior
            // receipt committed and deleted the pending record.
            return nil
        }
        try commitLocalRotation(pending)
        keyStore.deletePendingLocalRotation(accountID: identity.accountID)
        return pending.purpose
    }

    private func makePendingRotationEnvelope(
        _ pending: RelayV2PendingLocalRotation,
        nowMilliseconds: UInt64
    ) throws -> RelayV2OuterEnvelope {
        guard let source = identity.routeID,
              let destination = identity.agentRouteID,
              let recipientKey = identity.agentAgreementPublicKey,
              let recipientGeneration = identity.agentKeyGeneration else {
            throw RelayV2ProtocolError.revoked
        }
        let sender: RelayV2KeyGeneration
        if pending.purpose == "kem" {
            guard pending.generation > 1,
                  let preparedIdentity = pending.updatedIdentity,
                  let previous = preparedIdentity.keyGenerations.first(where: {
                      $0.generation == pending.generation - 1
                  }) else {
                throw RelayV2ProtocolError.conflict("Previous device KEM is unavailable")
            }
            sender = previous
        } else if let current = identity.currentKeys {
            sender = current
        } else {
            throw RelayV2ProtocolError.revoked
        }
        let publicKey: Data
        if pending.purpose == "kem" {
            guard let preparedIdentity = pending.updatedIdentity,
                  let prepared = preparedIdentity.keyGenerations.first(where: {
                      $0.generation == pending.generation
                  }) else {
                throw RelayV2ProtocolError.conflict("Prepared device KEM is unavailable")
            }
            publicKey = try prepared.agreementPublicKey
        } else {
            guard let prepared = pending.updatedPreview else {
                throw RelayV2ProtocolError.conflict("Prepared preview key is unavailable")
            }
            publicKey = try RelayV2Crypto.agreementPublicKey(from: prepared.privateKey)
        }
        let expiry = nowMilliseconds + 24 * 60 * 60 * 1_000
        let stableKey = "key_rotate:\(pending.purpose):\(pending.generation):renew:\(nowMilliseconds)"
        let messageID = RelayV2Wire.base64URL(
            Data(SHA256.hash(data: Data(stableKey.utf8))).prefix(16)
        )
        let body: [String: JSONValue] = [
            "purpose": .string(pending.purpose),
            "generation": .number(Double(pending.generation)),
            "public_key": .string(RelayV2Wire.base64URL(publicKey)),
            "previous_not_after_ms": .number(Double(pending.previousNotAfterMilliseconds)),
        ]
        let message = try RelayV2SecureMessage(
            messageID: messageID,
            kind: .keyRotate,
            senderKeyGeneration: sender.generation,
            createdAtMilliseconds: nowMilliseconds,
            expiresAtMilliseconds: expiry,
            body: body
        )
        let header = try RelayV2OuterHeader(
            source: source,
            destination: destination,
            messageID: messageID,
            messageClass: .control,
            expiresAtMilliseconds: expiry,
            recipientKeyGeneration: recipientGeneration
        )
        let envelope = try RelayV2Crypto.sealAuthenticatedEnvelope(
            header: header,
            message: message,
            recipientPublicKey: recipientKey,
            senderAgreementPrivateKey: sender.agreementPrivateKey,
            senderSigningPrivateKey: sender.signingPrivateKey,
            purpose: .control,
            direction: .deviceToAgent
        )
        try recordOutboundEncryption()
        return envelope
    }

    private func recordOutboundEncryption() throws {
        let current = identity.outboundEncryptedMessageCount ?? 0
        identity.outboundEncryptedMessageCount = current == UInt64.max ? current : current + 1
        try keyStore.saveIdentity(identity)
    }

    private func commitLocalRotation(_ pending: RelayV2PendingLocalRotation) throws {
        if let updated = pending.updatedIdentity {
            identity = updated
            try keyStore.saveIdentity(updated)
        }
        if let preview = pending.updatedPreview {
            try keyStore.savePreviewKey(preview)
            if let push = try keyStore.loadPushRegistrationState(accountID: identity.accountID) {
                let publicKey = try RelayV2Crypto.agreementPublicKey(from: preview.privateKey)
                try keyStore.savePushRegistrationState(.init(
                    accountID: push.accountID,
                    endpointID: push.endpointID,
                    appAttestKeyID: push.appAttestKeyID,
                    pendingAttestation: push.pendingAttestation,
                    pendingRequestBody: push.pendingRequestBody,
                    pendingRequestExpiresAtMilliseconds: push.pendingRequestExpiresAtMilliseconds,
                    attestationPhase: push.attestationPhase,
                    installationNonce: push.installationNonce,
                    previewPublicKey: publicKey,
                    environment: push.environment
                ))
            }
        }
    }

    private func refreshRotatedPreviewRegistration() async throws {
        guard let hubURL = identity.hubURL,
              let tokenHex = KeychainService.loadAPNsDeviceToken(),
              let token = Self.decodeHex(tokenHex), !token.isEmpty,
              try keyStore.loadPushRegistrationState(accountID: identity.accountID)?.endpointID != nil else { return }
        let push = try RelayV2PushRegistrationClient(baseURL: hubURL, keyStore: keyStore)
        try await push.refreshToken(
            accountID: identity.accountID,
            apnsToken: token,
            bundleID: Bundle.main.bundleIdentifier ?? "ai.hermes.app"
        )
    }

    private static func decodeHex(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    func applyReceipt(_ message: RelayV2SecureMessage) async throws {
        guard message.body["jsonrpc"]?.stringValue == "2.0",
              let clientID = message.body["id"]?.stringValue,
              RelayV2Wire.isToken(clientID) else {
            throw RelayV2ProtocolError.invalidArgument(field: "rpc_response")
        }
        let hasResult = message.body["result"] != nil
        let error = message.body["error"]?.objectValue
        guard hasResult != (error != nil) else {
            throw RelayV2ProtocolError.invalidArgument(field: "rpc_response")
        }
        let code: RelayV2ErrorCode?
        if let error {
            guard let rawCode = error["code"]?.stringValue,
                  let recognized = RelayV2ErrorCode(rawValue: rawCode) else {
                throw RelayV2ProtocolError.invalidArgument(field: "rpc_response.error.code")
            }
            code = recognized
        } else {
            code = nil
        }
        if code == .revoked {
            // Persist the account tombstone before resolving the command row or
            // allowing the caller to observe a terminal RPC result.
            try await persistTerminalRevocation(
                source: "rpc_response",
                messageID: message.messageID
            )
            let completedCommand = await resolveRevokedCommandForTerminalBoundary(
                clientMessageID: clientID
            )
            if let completedCommand {
                await onCommandResolution?(clientID, completedCommand.kind, .revoked)
            }
            await hub.disconnect()
            throw RelayV2ProtocolError.revoked
        }
        let completedCommand = try await workRepository.relayV2Command(
            accountID: identity.accountID,
            clientMessageID: clientID
        )
        try await workRepository.resolveRelayV2Command(
            accountID: identity.accountID,
            clientMessageID: clientID,
            errorCode: code
        )
        if let command = completedCommand {
            await onCommandResolution?(clientID, command.kind, code)
        }
        if let continuation = pendingRPC.removeValue(forKey: clientID) {
            if let code {
                continuation.resume(throwing: RelayV2ProtocolError.remote(code, retryAfterSeconds: nil))
            } else {
                continuation.resume(returning: message.body["result"] ?? .null)
            }
        }
        if code == nil,
           let result = message.body["result"]?.objectValue,
           let origin = result["origin_session_id"]?.stringValue,
           let live = result["live_session_id"]?.stringValue {
            let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
            try await database.bindSessionAlias(
                accountID: identity.accountID,
                originSessionID: origin,
                liveSessionID: live,
                nowMilliseconds: nowMilliseconds
            )
            if completedCommand?.kind == .prompt,
               let payload = completedCommand.flatMap({
                   try? JSONDecoder().decode(JSONValue.self, from: $0.payloadJSON)
               }), let text = payload["params"]?["text"]?.stringValue {
                try await database.insertOptimisticItem(
                    accountID: identity.accountID,
                    sessionID: origin,
                    itemID: clientID,
                    body: ["text": .string(text)],
                    nowMilliseconds: nowMilliseconds
                )
                let items = try await database.items(
                    accountID: identity.accountID, sessionID: origin
                )
                await onProjection?(origin, items.map(\.chatItem), [])
            }
            await onSessionBinding?(origin, live)
        }
    }

    func request(
        kind: RelayV2CommandKind,
        sessionID: String? = nil,
        params: [String: JSONValue],
        timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        let clientMessageID = RelayV2Identifiers.canonicalUUID()
        let operationID = "op_\(RelayV2Identifiers.canonicalUUID())"
        return try await withCheckedThrowingContinuation { continuation in
            // Install the waiter before the durable row becomes visible to a
            // concurrently running drain. A loopback Agent can otherwise
            // answer between enqueue's suspension and this registration.
            pendingRPC[clientMessageID] = continuation
            Task {
                await self.persistAndDrainRequest(
                    operationID: operationID,
                    clientMessageID: clientMessageID,
                    sessionID: sessionID,
                    kind: kind,
                    params: params
                )
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.timeoutRequest(clientMessageID)
            }
        }
    }

    private func persistAndDrainRequest(
        operationID: String,
        clientMessageID: String,
        sessionID: String?,
        kind: RelayV2CommandKind,
        params: [String: JSONValue]
    ) async {
        do {
            _ = try await workRepository.enqueueRelayV2Command(
                operationID: operationID,
                clientMessageID: clientMessageID,
                accountID: identity.accountID,
                sessionID: sessionID,
                kind: kind,
                payload: params
            )
            await drainCommands(repository: workRepository)
        } catch {
            pendingRPC.removeValue(forKey: clientMessageID)?.resume(throwing: error)
        }
    }

    private func timeoutRequest(_ clientMessageID: String) {
        guard let continuation = pendingRPC.removeValue(forKey: clientMessageID) else { return }
        continuation.resume(
            throwing: RelayV2ProtocolError.transport("Relay request timed out")
        )
    }

    func sendCommand(
        _ command: RelayV2CommandRecord,
        repository: WorkRepository
    ) async throws -> RelayV2HubAccepted {
        try await requireDurableAccountActive()
        guard command.accountID == identity.accountID else {
            throw RelayV2ProtocolError.revoked
        }
        if command.envelopeJSON == nil {
            try await rotateDeviceKeysIfNeeded()
        }
        guard let source = identity.routeID,
              let destination = identity.agentRouteID,
              let recipientKey = identity.agentAgreementPublicKey,
              let recipientGeneration = identity.agentKeyGeneration,
              let keys = identity.currentKeys else {
            throw RelayV2ProtocolError.revoked
        }
        let nowDate = Date().timeIntervalSince1970
        guard let fixedExpiresAt = command.fixedExpiresAt, fixedExpiresAt > nowDate else {
            throw RelayV2ProtocolError.expired
        }
        if let encoded = command.envelopeJSON {
            let existing = try RelayV2OuterEnvelope.decodeStrict(from: encoded)
            guard existing.header.expiresAtMilliseconds > UInt64(nowDate * 1_000) else {
                throw RelayV2ProtocolError.expired
            }
            // A revoke can commit while envelope decoding suspends elsewhere in
            // this actor. Recheck at the final transport boundary.
            try await requireDurableAccountActive()
            return try await hub.post(existing)
        }
        let now = UInt64(command.createdAt * 1_000)
        let expiry = UInt64(fixedExpiresAt * 1_000)
        let stableMID = Data(SHA256.hash(data: Data("\(command.operationID)|\(command.payloadHash)".utf8))).prefix(16)
        let messageID = RelayV2Wire.base64URL(Data(stableMID))
        guard let payload = try JSONDecoder().decode(
            JSONValue.self,
            from: command.payloadJSON
        ).objectValue else {
            throw RelayV2ProtocolError.invalidArgument(field: "command_payload")
        }
        let message = try RelayV2SecureMessage(
            messageID: messageID,
            kind: .rpcRequest,
            senderKeyGeneration: keys.generation,
            createdAtMilliseconds: now,
            expiresAtMilliseconds: expiry,
            body: payload
        )
        let header = try RelayV2OuterHeader(
            source: source,
            destination: destination,
            messageID: messageID,
            messageClass: .command,
            expiresAtMilliseconds: expiry,
            recipientKeyGeneration: recipientGeneration
        )
        let envelope = try RelayV2Crypto.sealAuthenticatedEnvelope(
            header: header,
            message: message,
            recipientPublicKey: recipientKey,
            senderAgreementPrivateKey: keys.agreementPrivateKey,
            senderSigningPrivateKey: keys.signingPrivateKey,
            purpose: .chat,
            direction: .deviceToAgent
        )
        // Count the newly sealed MID before the WAL write. A crash can rotate
        // one message early, but can never under-count and overuse a KEM.
        try recordOutboundEncryption()
        let persisted = try await repository.persistRelayV2Envelope(
            operationID: command.operationID,
            envelope: envelope
        )
        try await requireDurableAccountActive()
        return try await hub.post(persisted)
    }

    func drainCommands(repository: WorkRepository, owner: String = UUID().uuidString) async {
        // Every caller records demand, including callers that arrive while the
        // single active owner is suspended in an actor-reentrant repository
        // claim. The owner consumes the newest generation only after an empty
        // claim, closing the enqueue-at-empty-tail lost-wakeup window.
        guard commandDrainAcceptingWakeups else { return }
        commandDrainGeneration &+= 1
        let epoch = commandDrainLifecycleEpoch
        let ownsWait = commandDrainTask == nil
        if ownsWait {
            startCommandDrainTask(
                repository: repository,
                owner: owner,
                epoch: epoch,
                observedGeneration: commandDrainGeneration
            )
        }
        // An overlapping wake only records demand. Waiting here would make a
        // caller that owns the resource unblocking the active drain deadlock
        // against that drain. The original caller follows the owned chain to
        // completion, including any atomic handoffs.
        guard ownsWait else { return }
        await waitForCommandDrainChain(epoch: epoch)
    }

    private func runCommandDrain(
        repository: WorkRepository,
        owner: String,
        epoch: UInt64,
        taskID: UInt64,
        observedGeneration initialGeneration: UInt64
    ) async -> UInt64 {
        var observedGeneration = initialGeneration
        var recheckingGeneration: UInt64?
        while true {
            guard !Task.isCancelled,
                  commandDrainAcceptingWakeups,
                  epoch == commandDrainLifecycleEpoch else { return observedGeneration }
            let command: RelayV2CommandRecord?
            do {
                #if DEBUG
                try await commandDrainBeforeClaimHookForTesting?()
                #endif
                guard !Task.isCancelled else { return observedGeneration }
                command = try await repository.claimRelayV2Command(
                    accountID: identity.accountID,
                    owner: owner
                )
            } catch { return observedGeneration }
            guard let command else {
                #if DEBUG
                await commandDrainEmptyTailHookForTesting?()
                #endif
                // If this owner was cancelled while suspended at the empty
                // boundary, do not consume the newer demand. The atomic exit
                // handoff below must transfer it to a fresh uncancelled task.
                guard !Task.isCancelled else { return observedGeneration }
                let currentGeneration = commandDrainGeneration
                if let targetGeneration = recheckingGeneration {
                    if targetGeneration == currentGeneration {
                        // Demand is consumed only after a successful claim has
                        // proven the queue empty at that generation. Any exit
                        // before this stable-empty point retains the older
                        // observed generation and therefore forces handoff.
                        observedGeneration = currentGeneration
                        return observedGeneration
                    }
                    recheckingGeneration = currentGeneration
                    continue
                }
                if observedGeneration != currentGeneration {
                    recheckingGeneration = currentGeneration
                    continue
                }
                return observedGeneration
            }
            do {
                let receipt = try await transmitCommand(
                    command,
                    repository: repository
                )
                try await repository.markRelayV2Command(
                    operationID: command.operationID,
                    state: receipt.accepted ? .accepted : .ambiguous,
                    onlyIfCurrentState: .sending
                )
            } catch let error as RelayV2ProtocolError {
                if case let .remote(code, retryAfter) = error {
                    let resolution: (RelayV2CommandState, RelayV2ErrorCode, Date?)
                    switch code {
                    case .gatewayAmbiguous:
                        resolution = (.ambiguous, code, Date().addingTimeInterval(retryAfter ?? 30))
                    case .gatewayOffline, .rateLimited, .mailboxFull, .internal:
                        resolution = (.retryWait, code, Date().addingTimeInterval(retryAfter ?? 30))
                    case .expired:
                        resolution = (.expired, code, nil)
                    case .invalidArgument, .unauthenticated, .revoked, .unsupportedVersion,
                         .notFound, .conflict, .alreadyResolved:
                        resolution = (.completed, code, nil)
                    }
                    if code == .revoked {
                        do {
                            // The account tombstone must win the WAL race before
                            // this command receives its terminal marker.
                            try await persistTerminalRevocation(
                                source: "command_http",
                                messageID: command.clientMessageID
                            )
                        } catch {
                            return observedGeneration
                        }
                        await markRevokedCommandForTerminalBoundary(
                            command,
                            repository: repository
                        )
                        await hub.disconnect()
                        return observedGeneration
                    }
                    try? await repository.markRelayV2Command(
                        operationID: command.operationID,
                        state: resolution.0,
                        errorCode: resolution.1,
                        retryAt: resolution.2,
                        onlyIfCurrentState: .sending
                    )
                    if resolution.0 == .retryWait || resolution.0 == .ambiguous {
                        return observedGeneration
                    }
                    continue
                }
                try? await repository.markRelayV2Command(
                    operationID: command.operationID,
                    state: error == .expired ? .expired : .retryWait,
                    errorCode: error == .expired ? .expired : .gatewayOffline,
                    retryAt: error == .expired ? nil : Date().addingTimeInterval(5),
                    onlyIfCurrentState: .sending
                )
                if error != .expired { return observedGeneration }
            } catch {
                await markCommandAfterUnknownSendOutcome(
                    command,
                    repository: repository
                )
                return observedGeneration
            }
        }
    }

    private func fenceRevokedIdentity() async {
        let shouldNotify = !isTerminallyRevoked
        keyStore.deleteIdentity(accountID: identity.accountID)
        isTerminallyRevoked = true
        connectionAcceptingAttempts = false
        connectionLifecycleEpoch &+= 1
        connectionAttemptTask?.cancel()
        receiveTask?.cancel()
        failureTask?.cancel()
        commandDrainAcceptingWakeups = false
        commandDrainLifecycleEpoch &+= 1
        cancelCommandRetryTimer()
        let waiters = pendingRPC.values
        pendingRPC.removeAll()
        waiters.forEach { $0.resume(throwing: RelayV2ProtocolError.revoked) }
        state = .failed(RelayV2ProtocolError.revoked.localizedDescription)
        if shouldNotify {
            await onTerminalRevocation?(identity.accountID)
        }
    }

    /// Source of truth for every terminal revoke path. The database commit is
    /// intentionally complete before Keychain deletion, command resolution,
    /// delivery receipts, seen markers, or Hub acknowledgements can occur.
    private func persistTerminalRevocation(
        source: String,
        messageID: String?
    ) async throws {
        try await database.recordAccountRevocation(
            accountID: identity.accountID,
            source: source,
            messageID: messageID,
            revokedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        #if DEBUG
        if await revocationAfterTombstoneHookForTesting?(source) == true {
            simulateProcessStopAfterRevocationTombstone()
            throw CancellationError()
        }
        #endif
        await fenceRevokedIdentity()
    }

    private func requireDurableAccountActive() async throws {
        if isTerminallyRevoked {
            keyStore.deleteIdentity(accountID: identity.accountID)
            throw RelayV2ProtocolError.revoked
        }
        if try await database.isAccountRevoked(accountID: identity.accountID) {
            await fenceRevokedIdentity()
            await hub.disconnect()
            throw RelayV2ProtocolError.revoked
        }
    }

    private static func isTerminalRevocation(_ error: any Error) -> Bool {
        guard let protocolError = error as? RelayV2ProtocolError else { return false }
        switch protocolError {
        case .revoked, .remote(.revoked, _): return true
        default: return false
        }
    }

    #if DEBUG
    private func simulateProcessStopAfterRevocationTombstone() {
        // Test-only crash boundary: quiesce every owned worker but deliberately
        // leave Keychain material untouched. A reconstructed client must discover
        // the durable tombstone and delete the key before it can reconnect/send.
        isTerminallyRevoked = true
        connectionAcceptingAttempts = false
        connectionLifecycleEpoch &+= 1
        connectionAttemptTask?.cancel()
        receiveTask?.cancel()
        failureTask?.cancel()
        commandDrainAcceptingWakeups = false
        commandDrainLifecycleEpoch &+= 1
        cancelCommandRetryTimer()
        let waiters = pendingRPC.values
        pendingRPC.removeAll()
        waiters.forEach { $0.resume(throwing: CancellationError()) }
        state = .failed("Relay process stopped after durable revocation")
    }
    #endif

    private func resolveRevokedCommandForTerminalBoundary(
        clientMessageID: String
    ) async -> RelayV2CommandRecord? {
        let repository = workRepository
        let accountID = identity.accountID
        return await Task {
            let command = try? await repository.relayV2Command(
                accountID: accountID,
                clientMessageID: clientMessageID
            )
            try? await repository.resolveRelayV2Command(
                accountID: accountID,
                clientMessageID: clientMessageID,
                errorCode: .revoked
            )
            return command
        }.value
    }

    private func markRevokedCommandForTerminalBoundary(
        _ command: RelayV2CommandRecord,
        repository: WorkRepository
    ) async {
        _ = await Task {
            try? await repository.markRelayV2Command(
                operationID: command.operationID,
                state: .completed,
                errorCode: .revoked,
                onlyIfCurrentState: .sending
            )
        }.value
    }

    private func markCommandAfterUnknownSendOutcome(
        _ command: RelayV2CommandRecord,
        repository: WorkRepository
    ) async {
        let mark = {
            try? await repository.markRelayV2Command(
                operationID: command.operationID,
                state: .ambiguous,
                errorCode: .gatewayAmbiguous,
                retryAt: Date().addingTimeInterval(30),
                onlyIfCurrentState: .sending
            )
        }
        if Task.isCancelled {
            // URLSession cancellation propagates into GRDB's async write. Use
            // a fresh, bounded task for the durable cleanup and await it as
            // part of the owned drain; this is not an untracked successor.
            _ = await Task { await mark() }.value
        } else {
            _ = await mark()
        }
    }

    private func transmitCommand(
        _ command: RelayV2CommandRecord,
        repository: WorkRepository
    ) async throws -> RelayV2HubAccepted {
        #if DEBUG
        if let commandDrainSendHookForTesting {
            return try await commandDrainSendHookForTesting(command)
        }
        #endif
        return try await sendCommand(command, repository: repository)
    }

    private func finishCommandDrain(
        repository: WorkRepository,
        epoch: UInt64,
        taskID: UInt64,
        observedGeneration: UInt64
    ) async {
        // A stale node can finish after disconnect/reconnect or after a newer
        // node replaced it. It must never clear or restart the current chain.
        guard taskID == commandDrainTaskID else { return }
        guard commandDrainAcceptingWakeups,
              epoch == commandDrainLifecycleEpoch else {
            clearCommandDrainTask(taskID: taskID)
            return
        }

        if observedGeneration != commandDrainGeneration {
            // Replace the owned node atomically while still on the actor.
            // Wakeups arriving before the successor executes only advance the
            // generation; no untracked task and no lifecycle gap exists.
            startCommandDrainTask(
                repository: repository,
                owner: UUID().uuidString,
                epoch: epoch,
                observedGeneration: commandDrainGeneration
            )
            return
        }

        let deadlineDiscovery = await nextCommandWakeDeadline(repository: repository)
        guard taskID == commandDrainTaskID,
              commandDrainAcceptingWakeups,
              epoch == commandDrainLifecycleEpoch else {
            clearCommandDrainTask(taskID: taskID)
            return
        }
        if observedGeneration != commandDrainGeneration {
            startCommandDrainTask(
                repository: repository,
                owner: UUID().uuidString,
                epoch: epoch,
                observedGeneration: commandDrainGeneration
            )
            return
        }
        let retryDeadline: Date?
        switch deadlineDiscovery {
        case .loaded(let deadline):
            retryDeadline = deadline
        case .failed:
            // A read failure is not proof that the outbox is empty. Retain an
            // owned, bounded wake so a transient database fault cannot cancel
            // the sole automatic retry path.
            retryDeadline = Date().addingTimeInterval(0.25)
        }
        updateCommandRetryTimer(
            deadline: retryDeadline,
            repository: repository,
            epoch: epoch
        )
        clearCommandDrainTask(taskID: taskID)
    }

    private func nextCommandWakeDeadline(
        repository: WorkRepository
    ) async -> CommandWakeDeadlineDiscovery {
        let accountID = identity.accountID
        let load: @Sendable () async throws -> [RelayV2CommandRecord] = {
            #if DEBUG
            if let hook = await self.commandWakeDeadlineLoadHookForTesting {
                return try await hook()
            }
            #endif
            return try await repository.relayV2Commands(accountID: accountID)
        }
        let commands: [RelayV2CommandRecord]
        do {
            if Task.isCancelled {
                // A cancelled drain still owns durable cleanup and deadline
                // discovery until it hands off or disconnect invalidates its epoch.
                commands = try await Task { try await load() }.value
            } else {
                commands = try await load()
            }
        } catch {
            return .failed
        }
        let now = Date().timeIntervalSince1970
        let deadline = commands.compactMap { command -> Date? in
            let retryFloor: Double
            switch command.state {
            case .queued, .sending, .retryWait:
                retryFloor = command.nextAttemptAt ?? now
            case .ambiguous:
                guard let nextAttemptAt = command.nextAttemptAt else { return nil }
                retryFloor = nextAttemptAt
            case .accepted, .completed, .expired:
                return nil
            }
            let leaseFloor = command.leaseExpiresAt ?? now
            return Date(timeIntervalSince1970: max(retryFloor, leaseFloor))
        }.min()
        return .loaded(deadline)
    }

    private func updateCommandRetryTimer(
        deadline: Date?,
        repository: WorkRepository,
        epoch: UInt64
    ) {
        guard commandDrainAcceptingWakeups,
              epoch == commandDrainLifecycleEpoch,
              let deadline else {
            cancelCommandRetryTimer()
            return
        }
        if let existingDeadline = commandRetryTimerDeadline,
           commandRetryTimerTask != nil,
           existingDeadline <= deadline {
            return
        }

        commandRetryTimerTask?.cancel()
        commandRetryTimerID &+= 1
        let timerID = commandRetryTimerID
        commandRetryTimerDeadline = deadline
        // A past-due row should retry promptly without becoming a hot loop if
        // the repository or transport keeps failing synchronously.
        let delay = max(0.25, deadline.timeIntervalSinceNow)
        commandRetryTimerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            await self.fireCommandRetryTimer(
                timerID: timerID,
                epoch: epoch,
                repository: repository
            )
        }
    }

    private func fireCommandRetryTimer(
        timerID: UInt64,
        epoch: UInt64,
        repository: WorkRepository
    ) async {
        guard timerID == commandRetryTimerID,
              commandDrainAcceptingWakeups,
              epoch == commandDrainLifecycleEpoch else { return }
        commandRetryTimerTask = nil
        commandRetryTimerDeadline = nil
        await drainCommands(
            repository: repository,
            owner: "retry-timer-\(timerID)"
        )
    }

    private func cancelCommandRetryTimer() {
        commandRetryTimerID &+= 1
        commandRetryTimerTask?.cancel()
        commandRetryTimerTask = nil
        commandRetryTimerDeadline = nil
    }

    private func startCommandDrainTask(
        repository: WorkRepository,
        owner: String,
        epoch: UInt64,
        observedGeneration: UInt64
    ) {
        commandDrainTaskID &+= 1
        let taskID = commandDrainTaskID
        commandDrainTask = Task { [weak self] in
            guard let self else { return }
            let finalGeneration = await self.runCommandDrain(
                repository: repository,
                owner: owner,
                epoch: epoch,
                taskID: taskID,
                observedGeneration: observedGeneration
            )
            await self.finishCommandDrain(
                repository: repository,
                epoch: epoch,
                taskID: taskID,
                observedGeneration: finalGeneration
            )
        }
    }

    private func clearCommandDrainTask(taskID: UInt64) {
        guard taskID == commandDrainTaskID else { return }
        commandDrainTask = nil
        #if DEBUG
        let waiters = commandDrainIdleWaitersForTesting
        commandDrainIdleWaitersForTesting.removeAll()
        waiters.forEach { $0.resume() }
        #endif
    }

    private func waitForCommandDrainChain(epoch: UInt64) async {
        while commandDrainAcceptingWakeups,
              epoch == commandDrainLifecycleEpoch,
              let task = commandDrainTask {
            await task.value
        }
    }

    private func stopCommandDrainLifecycle() async {
        commandDrainAcceptingWakeups = false
        commandDrainLifecycleEpoch &+= 1
        let taskID = commandDrainTaskID
        let task = commandDrainTask
        let retryTimer = commandRetryTimerTask
        commandRetryTimerID &+= 1
        commandRetryTimerTask = nil
        commandRetryTimerDeadline = nil
        task?.cancel()
        retryTimer?.cancel()
        await task?.value
        await retryTimer?.value
        if taskID == commandDrainTaskID {
            clearCommandDrainTask(taskID: taskID)
        }
    }

    private func resumeCommandDrainLifecycle() {
        guard !commandDrainAcceptingWakeups else { return }
        commandDrainLifecycleEpoch &+= 1
        commandDrainAcceptingWakeups = true
    }

    #if DEBUG
    struct ConnectionLifecycleSnapshotForTesting: Sendable {
        let connectionAttemptActive: Bool
        let receiveWorkerActive: Bool
        let failureWorkerActive: Bool
        let commandDrainAcceptingWakeups: Bool
        let commandRetryTimerActive: Bool
    }

    func setConnectionAfterHubConnectHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        connectionAfterHubConnectHookForTesting = hook
    }

    func setConnectionDidInvalidateHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        connectionDidInvalidateHookForTesting = hook
    }

    func connectionLifecycleSnapshotForTesting() -> ConnectionLifecycleSnapshotForTesting {
        ConnectionLifecycleSnapshotForTesting(
            connectionAttemptActive: connectionAttemptTask != nil,
            receiveWorkerActive: receiveTask != nil,
            failureWorkerActive: failureTask != nil,
            commandDrainAcceptingWakeups: commandDrainAcceptingWakeups,
            commandRetryTimerActive: commandRetryTimerTask != nil
        )
    }

    func setCommandDrainEmptyTailHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        commandDrainEmptyTailHookForTesting = hook
    }

    func setCommandDrainBeforeClaimHookForTesting(
        _ hook: (@Sendable () async throws -> Void)?
    ) {
        commandDrainBeforeClaimHookForTesting = hook
    }

    func setCommandDrainSendHookForTesting(
        _ hook: (@Sendable (RelayV2CommandRecord) async throws -> RelayV2HubAccepted)?
    ) {
        commandDrainSendHookForTesting = hook
    }

    func setCommandWakeDeadlineLoadHookForTesting(
        _ hook: (@Sendable () async throws -> [RelayV2CommandRecord])?
    ) {
        commandWakeDeadlineLoadHookForTesting = hook
    }

    func setRevocationAfterTombstoneHookForTesting(
        _ hook: (@Sendable (String) async -> Bool)?
    ) {
        revocationAfterTombstoneHookForTesting = hook
    }

    func waitForCommandDrainIdleForTesting() async {
        guard commandDrainTask != nil else { return }
        await withCheckedContinuation { commandDrainIdleWaitersForTesting.append($0) }
    }

    func cancelCommandDrainTaskForTesting() {
        commandDrainTask?.cancel()
    }

    func resumeCommandDrainLifecycleForTesting() {
        resumeCommandDrainLifecycle()
    }
    #endif
}
