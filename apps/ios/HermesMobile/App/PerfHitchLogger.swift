#if DEBUG
import Foundation
import QuartzCore
import os.log

/// DEBUG-only activation counters for the imperative scroll machinery (ARCH37
/// Step 1 risk gate). The redesign's claim is that per-session ScrollView identity
/// (`.id(activeStoredId)`) makes the native `.defaultScrollAnchor(.bottom)` land
/// the open BY CONSTRUCTION — so the always-on CLAMP and the one-shot LATCH should
/// fire toward ZERO on a clean cached open. These counters let `PerfHitchLogger`
/// print latch/clamp activations alongside the hitch numbers so the matrix proves
/// the native anchor carries the open before Step 6 deletes the machinery. Plain
/// nonisolated atomics-free counters (incremented only on the main actor from the
/// geometry reader) — allocation-free, zero steady-state cost.
enum ScrollInstrumentation {
    nonisolated(unsafe) static var clampActivations = 0
    nonisolated(unsafe) static var latchActivations = 0

    static func clampFired() { clampActivations += 1 }
    static func latchFired() { latchActivations += 1 }
}

/// DEBUG-only main-thread hitch logger driven by a `CADisplayLink`.
///
/// Activated by the `HERMES_PERF_LOG=1` launch-environment variable. It measures
/// the wall-clock interval between consecutive display refreshes on the main
/// thread and counts how many exceeded 1.5x and 3x the display's *target*
/// interval (the ProMotion-aware `targetTimestamp - timestamp`, so it adapts to
/// 60Hz vs 120Hz automatically). Every 2 seconds it emits ONE line:
///
///     PERF window=2s frames=N hitch1.5x=N hitch3x=N worst_ms=N
///
/// A "hitch" here means the main runloop did not return to service the next
/// vsync on time — i.e. a dropped frame, the numeric proxy for the user's
/// "not smooth". The logger is allocation-free in steady state (only scalar
/// counters mutate per frame) so it does not itself perturb the measurement.
///
/// The line goes to BOTH `os_log` (so `xcrun simctl spawn <udid> log stream`
/// can capture it) AND `print` (so `--console-pty` / stdout capture works), and
/// is ALSO appended to a file in the app container (`tmp/hermes-perf.log`) as a
/// last-resort capture channel that survives even when no log stream is attached.
///
/// Never compiled into Release.
@MainActor
final class PerfHitchLogger {
    static let shared = PerfHitchLogger()

    private let logger = Logger(subsystem: "ai.hermes.mobile", category: "perf")
    private var displayLink: CADisplayLink?

    /// The previous frame's presentation timestamp; `nil` until the first tick.
    private var lastTimestamp: CFTimeInterval?
    /// Counters for the current 2s window.
    private var windowStart: CFTimeInterval = 0
    private var frameCount = 0
    private var hitch15Count = 0
    private var hitch3Count = 0
    private var worstFrameMs: Double = 0

    /// Cached file handle for the container log channel (best-effort).
    private let logFileURL: URL = {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-perf.log")
    }()

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["HERMES_PERF_LOG"] == "1"
    }

    private init() {}

    /// Begin logging. Idempotent — a second call is a no-op while running.
    func start() {
        guard displayLink == nil else { return }
        // Truncate any prior container log so a fresh run starts clean.
        try? Data().write(to: logFileURL)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Run on the main runloop in common modes so it ticks during scroll
        // tracking too (the very window we want to measure).
        link.add(to: .main, forMode: .common)
        displayLink = link
        windowStart = CACurrentMediaTime()
        emit("PERF logger started (HERMES_PERF_LOG=1)")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        // Target interval for THIS refresh (ProMotion-aware): the time the system
        // budgeted between this frame and the next. ~16.7ms @60Hz, ~8.3ms @120Hz.
        let targetInterval = link.targetTimestamp - link.timestamp
        defer { lastTimestamp = now }

        guard let last = lastTimestamp, targetInterval > 0 else { return }
        let delta = now - last
        frameCount += 1
        let deltaMs = delta * 1000.0
        if deltaMs > worstFrameMs { worstFrameMs = deltaMs }
        if delta > targetInterval * 1.5 { hitch15Count += 1 }
        if delta > targetInterval * 3.0 { hitch3Count += 1 }

        // Emit a window summary every ~2 seconds.
        if now - windowStart >= 2.0 {
            let line = String(
                format: "PERF window=2s frames=%d hitch1.5x=%d hitch3x=%d worst_ms=%.1f cacheHit=%d cacheMiss=%d clamp=%d latch=%d",
                frameCount, hitch15Count, hitch3Count, worstFrameMs,
                RenderCache.hits, RenderCache.misses,
                ScrollInstrumentation.clampActivations, ScrollInstrumentation.latchActivations)
            emit(line)
            windowStart = now
            frameCount = 0
            hitch15Count = 0
            hitch3Count = 0
            worstFrameMs = 0
        }
    }

    /// Emit one line to all three channels (os_log + stdout + container file).
    private func emit(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        print(line)
        if let data = (line + "\n").data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else if let data = (line + "\n").data(using: .utf8) {
            // File did not exist yet (first emit after truncate failure) — create.
            try? data.write(to: logFileURL)
        }
    }
}
#endif
