import Foundation
import OSLog

/// Timestamped connect fast-path trace (DAILY-DRIVER SPEC N3 / A1).
///
/// Records the cold-open connect sequence so an instrumented run can PROVE the
/// A1 budget (cold-open → composer interactive ≤2s on the LAN relay path):
///
///   cold_open_start → cache_paint → socket_open → transport_ready → composer_interactive
///
/// Each milestone is emitted BOTH as an `OSSignposter` event (Instruments /
/// `signpost` tooling) AND as a structured `os.Logger` line tagged `[FASTPATH]`
/// with the millisecond offset from `cold_open_start`, so the sequence + deltas
/// can be recovered from the unified log with a single predicate:
///
///   xcrun simctl spawn booted log stream --level info \
///     --predicate 'subsystem == "HermesMobile" AND category == "ConnectFastPath"'
///
/// The trace is additive and never gates behaviour: it only observes. The time
/// source is injectable so unit tests can assert the delta math deterministically
/// without a live clock or socket.
@MainActor
final class ConnectTrace {
    static let shared = ConnectTrace()

    /// The ordered connect milestones. Raw values are the stable log labels.
    enum Milestone: String, CaseIterable, Sendable {
        case coldOpen = "cold_open_start"
        case cachePaint = "cache_paint"
        case socketOpen = "socket_open"
        case transportReady = "transport_ready"
        case composerInteractive = "composer_interactive"
    }

    private static let logger = Logger(subsystem: "HermesMobile", category: "ConnectFastPath")
    private static let signposter = OSSignposter(subsystem: "HermesMobile", category: "ConnectFastPath")

    /// Injectable monotonic time source (seconds). Tests substitute a fake clock
    /// to pin exact deltas; production uses ``SystemConnectClock``.
    var clock: any ConnectClock = SystemConnectClock()

    /// The `cold_open_start` reference instant (seconds); deltas are relative to it.
    private(set) var startSeconds: Double?
    /// Recorded instant (seconds) per milestone for the current run.
    private(set) var marks: [Milestone: Double] = [:]

    /// Begin a fresh measurement run: reset all marks and stamp `cold_open_start`.
    /// Called once at the top of the app's launch `.task`.
    func begin() {
        startSeconds = clock.now()
        marks = [:]
        mark(.coldOpen)
    }

    /// Record a milestone at the current instant and emit it to the log + signpost
    /// stream. FIRST-OCCURRENCE semantics: within a run a milestone is only stamped
    /// once, so a latched/repeated event (a second cache paint, a reconnect crossing
    /// back to `.connected`) does not overwrite the connect-sequence instant. `begin`
    /// resets for a fresh run.
    func mark(_ milestone: Milestone) {
        guard marks[milestone] == nil else { return }
        let now = clock.now()
        marks[milestone] = now
        let offsetMs = elapsedMs(to: milestone) ?? 0
        Self.logger.info("[FASTPATH] milestone=\(milestone.rawValue, privacy: .public) t_ms=\(offsetMs, format: .fixed(precision: 1))")
        // `OSSignposter.emitEvent` requires a `StaticString` name, so the signpost
        // carries a fixed channel label; the per-milestone identity + timestamp is
        // in the structured log line above (the grep-able evidence channel).
        Self.signposter.emitEvent("connect_fastpath")
    }

    /// Milliseconds from `cold_open_start` to `milestone`, or `nil` if either is
    /// unrecorded.
    func elapsedMs(to milestone: Milestone) -> Double? {
        guard let startSeconds, let t = marks[milestone] else { return nil }
        return (t - startSeconds) * 1000
    }

    /// Milliseconds between two recorded milestones (`to` − `from`), or `nil` if
    /// either is unrecorded.
    func deltaMs(from: Milestone, to: Milestone) -> Double? {
        guard let a = marks[from], let b = marks[to] else { return nil }
        return (b - a) * 1000
    }
}

/// A monotonic time source returning seconds.
@MainActor
protocol ConnectClock {
    func now() -> Double
}

/// Production clock: seconds since the clock was created, from `ContinuousClock`
/// (monotonic, unaffected by wall-clock changes).
@MainActor
final class SystemConnectClock: ConnectClock {
    private let base = ContinuousClock.now

    func now() -> Double {
        let duration = base.duration(to: ContinuousClock.now)
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
