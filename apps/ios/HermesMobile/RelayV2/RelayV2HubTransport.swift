import CryptoKit
import Foundation

struct RelayV2HubConfiguration: Equatable, Sendable {
    let baseURL: URL
    let routeID: String
    let routeSigningPrivateKey: Data

    init(baseURL: URL, routeID: String, routeSigningPrivateKey: Data) throws {
        guard Self.isTrusted(baseURL),
              RelayV2Wire.isToken(routeID), routeSigningPrivateKey.count == 32 else {
            throw RelayV2ProtocolError.invalidArgument(field: "hub_configuration")
        }
        self.baseURL = baseURL
        self.routeID = routeID
        self.routeSigningPrivateKey = routeSigningPrivateKey
    }

    private static func isTrusted(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        #if DEBUG
        // Plaintext is a simulator/developer escape hatch only, and must be
        // explicit in the configured URL. Release builds never admit it.
        if scheme == "http", isLoopback(host) { return true }
        #endif
        return false
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        if host.hasPrefix("127.") { return true }
        return false
    }
}

struct RelayV2HubAccepted: Codable, Equatable, Sendable {
    let accepted: Bool
    let deduplicated: Bool
    let stored: Bool
    let messageID: String

    enum CodingKeys: String, CodingKey {
        case accepted, deduplicated, stored
        case messageID = "mid"
    }
}

actor RelayV2HubTransport {
    nonisolated let messages: AsyncStream<RelayV2OuterEnvelope>
    private nonisolated let messageContinuation: AsyncStream<RelayV2OuterEnvelope>.Continuation
    nonisolated let failures: AsyncStream<RelayV2ProtocolError>
    private nonisolated let failureContinuation: AsyncStream<RelayV2ProtocolError>.Continuation

    private let configuration: RelayV2HubConfiguration
    private let session: URLSession
    private let readinessProbeForTesting: (@Sendable () async throws -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    #if DEBUG
    private var publishedFailureCountForTesting = 0
    #endif

    init(
        configuration: RelayV2HubConfiguration,
        session: URLSession? = nil,
        readinessProbeForTesting: (@Sendable () async throws -> Void)? = nil
    ) {
        self.configuration = configuration
        self.readinessProbeForTesting = readinessProbeForTesting
        (messages, messageContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        (failures, failureContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = true
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(
                configuration: config,
                delegate: RelayV2NoRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    /// Returns only after the authenticated WebSocket handshake is usable. A
    /// resumed task is not an open socket; the ping round-trip is the readiness
    /// barrier that exposes HTTP 401/403 before callers report `.open`.
    func connect() async throws {
        disconnect()
        let path = "/v2/socket"
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = configuration.baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = path
        components?.query = nil
        guard let url = components?.url else {
            throw RelayV2ProtocolError.invalidArgument(field: "hub_url")
        }
        var request = URLRequest(url: url)
        try authorize(&request, method: "GET", path: path, body: Data())
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        generation &+= 1
        let activeGeneration = generation
        socket.resume()
        do {
            if let readinessProbeForTesting {
                try await readinessProbeForTesting()
            } else {
                try await waitForReadiness(socket)
            }
            guard activeGeneration == generation, self.socket === socket else {
                throw CancellationError()
            }
        } catch {
            let mapped = protocolError(for: error, socket: socket)
            if activeGeneration == generation, self.socket === socket {
                generation &+= 1
                socket.cancel(with: .normalClosure, reason: nil)
                self.socket = nil
            }
            throw mapped
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket, generation: activeGeneration)
        }
    }

    func disconnect() {
        generation &+= 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    func post(_ envelope: RelayV2OuterEnvelope) async throws -> RelayV2HubAccepted {
        let body = try envelope.canonicalJSON()
        var request = URLRequest(url: try endpoint(path: "/v2/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "X-Hermes-Protocol")
        request.httpBody = body
        try authorize(&request, method: "POST", path: "/v2/messages", body: body)
        let (data, response) = try await session.data(for: request)
        try requireSuccess(response: response, data: data)
        try RelayV2Wire.requireExactObjectKeys(
            data, keys: ["accepted", "deduplicated", "stored", "mid"]
        )
        let receipt = try JSONDecoder().decode(RelayV2HubAccepted.self, from: data)
        guard receipt.accepted, receipt.messageID == envelope.header.messageID else {
            throw RelayV2ProtocolError.unauthenticated
        }
        return receipt
    }

    func acknowledge(_ messageIDs: [String]) async throws {
        let unique = Array(Set(messageIDs)).sorted()
        guard !unique.isEmpty, unique.count <= 256,
              unique.allSatisfy({ (try? RelayV2Wire.decodeBase64URL($0, exactBytes: 16)) != nil }) else {
            throw RelayV2ProtocolError.invalidArgument(field: "message_ids")
        }
        let body = try RelayV2Wire.canonicalJSON(["message_ids": unique])
        let path = "/v2/acks"
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        try authorize(&request, method: "POST", path: path, body: body)
        let (data, response) = try await session.data(for: request)
        try requireSuccess(response: response, data: data)
    }

    func sendOnSocket(_ envelope: RelayV2OuterEnvelope) async throws {
        guard let socket else { throw RelayV2ProtocolError.transport("Relay Hub socket is closed") }
        let envelopeObject = try JSONSerialization.jsonObject(with: envelope.canonicalJSON())
        let wire = try JSONSerialization.data(
            withJSONObject: ["type": "message", "envelope": envelopeObject],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try await socket.send(.data(wire))
    }

    private func receiveLoop(socket: URLSessionWebSocketTask, generation: UInt64) async {
        while generation == self.generation {
            do {
                let message = try await socket.receive()
                guard generation == self.generation else { return }
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                guard data.count <= 300_000,
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(root.keys) == ["type", "envelope"],
                      root["type"] as? String == "message",
                      let envelope = root["envelope"] as? [String: Any] else {
                    throw RelayV2ProtocolError.invalidArgument(field: "hub_socket_frame")
                }
                let envelopeData = try JSONSerialization.data(
                    withJSONObject: envelope,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
                let decoded = try RelayV2OuterEnvelope.decodeStrict(from: envelopeData)
                if case .dropped = messageContinuation.yield(decoded) {
                    throw RelayV2ProtocolError.transport("Relay Hub receive buffer overflow")
                }
            } catch {
                publishFailure(
                    protocolError(for: error, socket: socket),
                    generation: generation
                )
                socket.cancel(with: .policyViolation, reason: nil)
                return
            }
        }
    }

    private func waitForReadiness(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            socket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func publishFailure(
        _ error: RelayV2ProtocolError,
        generation loopGeneration: UInt64
    ) {
        // A cancelled socket can finish its receive after a new generation is
        // already open. Never let that stale catch poison the fresh worker's
        // one-element failure buffer.
        guard loopGeneration == generation else { return }
        #if DEBUG
        publishedFailureCountForTesting += 1
        #endif
        failureContinuation.yield(error)
    }

    private func protocolError(
        for error: any Error,
        socket: URLSessionWebSocketTask
    ) -> RelayV2ProtocolError {
        if let typed = error as? RelayV2ProtocolError { return typed }
        if let http = socket.response as? HTTPURLResponse {
            switch http.statusCode {
            case 401: return .unauthenticated
            case 403: return .remote(.revoked, retryAfterSeconds: nil)
            default:
                if !(200..<300).contains(http.statusCode) {
                    return .transport("Relay Hub WebSocket handshake failed (HTTP \(http.statusCode))")
                }
            }
        }
        if socket.closeCode.rawValue == 4401 || socket.closeCode.rawValue == 4403 {
            return .remote(.revoked, retryAfterSeconds: nil)
        }
        if let reason = socket.closeReason.flatMap({ String(data: $0, encoding: .utf8) }),
           reason.uppercased().contains(RelayV2ErrorCode.revoked.rawValue) {
            return .remote(.revoked, retryAfterSeconds: nil)
        }
        return .transport(error.localizedDescription)
    }

    #if DEBUG
    func connectionGenerationForTesting() -> UInt64 { generation }

    func simulateReceiveFailureForTesting(
        generation loopGeneration: UInt64,
        error: RelayV2ProtocolError
    ) {
        publishFailure(error, generation: loopGeneration)
    }

    func publishedFailureCountForTestingValue() -> Int {
        publishedFailureCountForTesting
    }
    #endif

    private func endpoint(path: String) throws -> URL {
        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ) else { throw RelayV2ProtocolError.invalidArgument(field: "hub_url") }
        components.path = path
        components.query = nil
        guard let url = components.url else {
            throw RelayV2ProtocolError.invalidArgument(field: "hub_url")
        }
        return url
    }

    private func authorize(
        _ request: inout URLRequest,
        method: String,
        path: String,
        body: Data
    ) throws {
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
            throw RelayV2ProtocolError.transport("Secure random generation failed")
        }
        let nonce = Data(nonceBytes)
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000)
        let payload = RelayV2Wire.lengthPrefixed(
            domain: Data("HRH2REQ".utf8),
            fields: [
                Data(method.uppercased().utf8),
                Data(path.utf8),
                Data(configuration.routeID.utf8),
                Data(String(timestamp).utf8),
                nonce,
                Data(SHA256.hash(data: body)),
            ]
        )
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: configuration.routeSigningPrivateKey
        )
        let signature = try key.signature(for: payload)
        request.setValue(configuration.routeID, forHTTPHeaderField: "X-Hermes-Route")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Hermes-Timestamp")
        request.setValue(RelayV2Wire.base64URL(nonce), forHTTPHeaderField: "X-Hermes-Nonce")
        request.setValue(RelayV2Wire.base64URL(signature), forHTTPHeaderField: "X-Hermes-Signature")
        request.setValue("2", forHTTPHeaderField: "X-Hermes-Protocol")
    }

    private func requireSuccess(response: URLResponse, data: Data) throws {
        guard data.count <= 65_536 else {
            throw RelayV2ProtocolError.transport("Relay Hub response exceeded the size limit")
        }
        guard let http = response as? HTTPURLResponse else {
            throw RelayV2ProtocolError.transport("Relay Hub returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let code: RelayV2ErrorCode
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = root["error"] as? [String: Any],
               let remoteCode = error["code"] as? String,
               let typed = RelayV2ErrorCode(rawValue: remoteCode) {
                code = typed
            } else {
                switch http.statusCode {
                case 400, 422: code = .invalidArgument
                case 401: code = .unauthenticated
                case 403: code = .revoked
                case 404: code = .notFound
                case 408, 410: code = .expired
                case 409: code = .conflict
                case 429: code = .rateLimited
                case 503: code = .gatewayOffline
                case 507: code = .mailboxFull
                default: code = .internal
                }
            }
            throw RelayV2ProtocolError.remote(
                code,
                retryAfterSeconds: Self.retryAfterSeconds(http.value(forHTTPHeaderField: "Retry-After"))
            )
        }
    }

    private static func retryAfterSeconds(_ value: String?) -> Double? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
