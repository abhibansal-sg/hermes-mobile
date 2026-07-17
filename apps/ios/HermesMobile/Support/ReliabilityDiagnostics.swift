import Foundation
import CryptoKit

/// Small, intentionally closed diagnostics vocabulary for connection recovery.
///
/// This is an in-memory trace only. Event payloads are typed, and identifiers
/// are stored as short one-way digests so a debug export cannot carry session
/// ids, job ids, prompts, URLs, or other user data by accident.
@MainActor
final class ReliabilityDiagnostics {
    static let capacity = 100
    static let shared = ReliabilityDiagnostics()

    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case websocketConnect = "websocket_connect"
        case websocketReady = "websocket_ready"
        case websocketClose = "websocket_close"
        case reconnectAttempt = "reconnect_attempt"
        case reconnectHeal = "reconnect_heal"
        case graceStart = "grace_start"
        case graceExpiry = "grace_expiry"
        case epochRejection = "epoch_rejection"
        case sessionSelect = "session_select"
        case sessionBind = "session_bind"
        case sessionSupersession = "session_supersession"
        case cachePaintStart = "cache_paint_start"
        case cachePaintFinish = "cache_paint_finish"
        case cachePaintFailure = "cache_paint_failure"
        case outboxWait = "outbox_wait"
        case outboxClaim = "outbox_claim"
        case outboxSubmit = "outbox_submit"
        case outboxAmbiguous = "outbox_ambiguous"
        case backgroundFlush = "background_flush"
        case foregroundLiveness = "foreground_liveness"
    }

    enum Outcome: String, Codable, Hashable, Sendable {
        case started
        case ready
        case closed
        case waiting
        case attempted
        case healed
        case expired
        case rejected
        case selected
        case bound
        case superseded
        case finished
        case failed
        case claimed
        case submitted
        case ambiguous
        case alive
        case dead
    }

    struct Event: Codable, Equatable, Sendable {
        let sequence: UInt64
        let timestamp: Date
        let kind: Kind
        /// A SHA-256 prefix, never the identifier supplied by the caller.
        let idHash: String?
        let epoch: UInt64?
        let count: Int?
        let durationMilliseconds: Int?
        let outcome: Outcome?
    }

    private struct Export: Codable {
        let version: Int
        let capacity: Int
        let events: [Event]
    }

    private(set) var events: [Event] = []
    private var nextSequence: UInt64 = 0

    func reset() {
        events.removeAll(keepingCapacity: true)
        nextSequence = 0
    }

    /// A stable, redacted export for the existing diagnostics share action.
    /// The export contains no caller-controlled strings other than enum values
    /// and fixed JSON keys.
    var redactedJSON: String {
        let export = Export(version: 1, capacity: Self.capacity, events: events)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(export) else { return "{\"version\":1,\"capacity\":100,\"events\":[]}" }
        return String(decoding: data, as: UTF8.self)
    }

    func websocketConnect(epoch: UInt64) {
        append(kind: .websocketConnect, epoch: epoch, outcome: .started)
    }

    func websocketReady(epoch: UInt64) {
        append(kind: .websocketReady, epoch: epoch, outcome: .ready)
    }

    func websocketClose(epoch: UInt64?) {
        append(kind: .websocketClose, epoch: epoch, outcome: .closed)
    }

    func reconnectAttempt(number: Int) {
        append(kind: .reconnectAttempt, count: max(0, number), outcome: .attempted)
    }

    func reconnectHeal(epoch: UInt64) {
        append(kind: .reconnectHeal, epoch: epoch, outcome: .healed)
    }

    func graceStarted(duration: Duration) {
        append(kind: .graceStart, durationMilliseconds: Self.milliseconds(duration), outcome: .started)
    }

    func graceExpired(attempt: Int) {
        append(kind: .graceExpiry, count: max(0, attempt), outcome: .expired)
    }

    func epochRejected(expected: UInt64?, received: UInt64?) {
        append(kind: .epochRejection, epoch: received ?? expected, count: expected.map { Int(min($0, UInt64(Int.max))) }, outcome: .rejected)
    }

    func sessionSelected(identifier: String) {
        append(kind: .sessionSelect, identifier: identifier, outcome: .selected)
    }

    func sessionBound(identifier: String, epoch: UInt64?) {
        append(kind: .sessionBind, identifier: identifier, epoch: epoch, outcome: .bound)
    }

    func sessionSuperseded(identifier: String?) {
        append(kind: .sessionSupersession, identifier: identifier, outcome: .superseded)
    }

    func cachePaintStarted(identifier: String?) {
        append(kind: .cachePaintStart, identifier: identifier, outcome: .started)
    }

    func cachePaintFinished(rowCount: Int, duration: Duration) {
        append(kind: .cachePaintFinish, count: max(0, rowCount), durationMilliseconds: Self.milliseconds(duration), outcome: .finished)
    }

    func cachePaintFailed(rowCount: Int, duration: Duration) {
        append(kind: .cachePaintFailure, count: max(0, rowCount), durationMilliseconds: Self.milliseconds(duration), outcome: .failed)
    }

    func outboxWait() {
        append(kind: .outboxWait, outcome: .waiting)
    }

    func outboxClaim(identifier: String) {
        append(kind: .outboxClaim, identifier: identifier, outcome: .claimed)
    }

    func outboxSubmit(identifier: String) {
        append(kind: .outboxSubmit, identifier: identifier, outcome: .submitted)
    }

    func outboxAmbiguous(identifier: String) {
        append(kind: .outboxAmbiguous, identifier: identifier, outcome: .ambiguous)
    }

    func backgroundFlushStarted() {
        append(kind: .backgroundFlush, outcome: .started)
    }

    func backgroundFlushFinished() {
        append(kind: .backgroundFlush, outcome: .finished)
    }

    func foregroundLiveness(alive: Bool) {
        append(kind: .foregroundLiveness, outcome: alive ? .alive : .dead)
    }

    private func append(
        kind: Kind,
        identifier: String? = nil,
        epoch: UInt64? = nil,
        count: Int? = nil,
        durationMilliseconds: Int? = nil,
        outcome: Outcome? = nil
    ) {
        let event = Event(
            sequence: nextSequence,
            timestamp: Date(),
            kind: kind,
            idHash: identifier.flatMap(Self.redactedID),
            epoch: epoch,
            count: count,
            durationMilliseconds: durationMilliseconds,
            outcome: outcome
        )
        nextSequence &+= 1
        events.append(event)
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let value = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return max(0, min(Int(value.rounded()), Int.max))
    }

    private static func redactedID(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
