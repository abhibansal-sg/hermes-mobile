import Foundation

// Wave-2 relay client — the WebSocket transport seam (RELAY-PHONE-PROTOCOL §1).
// A minimal abstraction over `URLSessionWebSocketTask`, deliberately kept
// separate from `GatewayWebSocketTask` (which carries gateway-specific ping /
// close-reason semantics): the relay lane is additive and self-contained. A test
// injects an in-process fake relay (§7) through this seam — zero network.

/// The subset of `URLSessionWebSocketTask` the relay client drives.
/// `URLSessionWebSocketTask` conforms with no behavioural change.
protocol RelayTransport: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: RelayTransport {}

/// Builds the WebSocket transport for a given request. The default factory hands
/// back a real `URLSessionWebSocketTask`; tests substitute a mock relay.
typealias RelayTransportFactory = @Sendable (URLRequest) -> RelayTransport
