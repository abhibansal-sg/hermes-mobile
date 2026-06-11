#if DEBUG
import Foundation

/// DEBUG-only deterministic UI seed for sim-based scroll verification.
///
/// Activated by the `HERMES_UITEST_SEED` launch environment variable
/// (`short` | `long`). It bypasses the network bootstrap entirely: forces the
/// connection phase to `.connected` (so `RootView` renders the main chat UI
/// instead of `WelcomeView`), sets a fake active stored session (so the chat
/// card renders `ChatView` rather than the empty-state placeholder), and seeds
/// the transcript through `ChatStore.debugSeedTranscript` so `ChatView`'s real
/// open-on-newest path (`handleSeedScroll` → `transcriptGeneration`) runs
/// exactly as in production — without needing a live gateway. Never compiled
/// into Release.
///
/// - `short`: 2 messages (well under a viewport) — verifies short chats stay
///   TOP-aligned under the header (not pinned to the bottom).
/// - `long`: 40 messages (well over a viewport) — verifies open-on-newest lands
///   at the bottom and the scroll-to-bottom pill works after scrolling up.
enum UITestSeed {
    static var requestedMode: String? {
        ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"]
    }

    @MainActor
    static func apply(_ mode: String, environment: AppEnvironment) {
        let count = mode.contains("short") ? 2 : 40
        var seeded: [ChatMessage] = []
        for i in 0..<count {
            let isUser = i.isMultiple(of: 2)
            let role: ChatRole = isUser ? .user : .assistant
            let body = isUser
                ? "UITest prompt #\(i + 1) — does the transcript land correctly?"
                : "UITest reply #\(i + 1). Lorem ipsum dolor sit amet, consectetur "
                    + "adipiscing elit, sed do eiusmod tempor incididunt ut labore et "
                    + "dolore magna aliqua."
            seeded.append(ChatMessage(role: role, text: body))
        }
        environment.connectionStore.phase = .connected

        // "switchlong" — FAITHFUL repro of the REAL session-switch open: open
        // session A (content), then switch to a LONG session B exactly as
        // SessionStore.open does it — set activeStoredId=B, then chat.reset()
        // (the EMPTY transcriptGeneration bump), then a deferred content seed.
        // This reproduces the reset-empty-bump-then-content-seed sequence the
        // device hits (which the launch-into-session modes never exercised).
        if mode == "switchlong" {
            var a: [ChatMessage] = []
            for i in 0..<6 {
                a.append(ChatMessage(
                    role: i.isMultiple(of: 2) ? .user : .assistant,
                    text: "Session A message #\(i + 1)"))
            }
            environment.sessionStore.activeStoredId = "uitest-A"
            environment.chatStore.debugSeedTranscript(a)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)  // read A, then "tap" B
                environment.sessionStore.activeStoredId = "uitest-B"  // set BEFORE reset (as open() does)
                environment.chatStore.reset()                         // the empty bump
                try? await Task.sleep(nanoseconds: 200_000_000)       // ~network seed delay
                environment.chatStore.debugSeedTranscript(seeded)     // B's long content
            }
            return
        }

        // "drawerswitch" — the MOST faithful repro: real open() driven through the
        // drawer, with the drawer-close spring animation running DURING the async
        // seed. Inject transcriptFetch (no gateway) so open() runs its real two-phase
        // seed. The test harness then: tap hamburger (open drawer) → tap Session B's
        // row → real open(B) (activeStoredId=B → reset empty bump → seedTranscript).
        if mode == "drawerswitch" {
            func stored(_ role: String, _ text: String, _ ts: Double) -> StoredMessage? {
                StoredMessage(json: .object([
                    "role": .string(role), "content": .string(text), "timestamp": .number(ts),
                ]))
            }
            func transcript(_ n: Int, _ tag: String) -> [StoredMessage] {
                (0..<n).compactMap { i in
                    stored(i.isMultiple(of: 2) ? "user" : "assistant",
                           "\(tag) message #\(i + 1) — Lorem ipsum dolor sit amet, consectetur "
                           + "adipiscing elit, sed do eiusmod tempor incididunt ut labore.",
                           Double(1_700_000_000 + i))
                }
            }
            let aMsgs = transcript(6, "A"), bMsgs = transcript(40, "B")
            environment.sessionStore.transcriptFetch = { id in
                try? await Task.sleep(nanoseconds: 200_000_000)  // network-like delay
                return id == "uitest-B" ? bMsgs : aMsgs
            }
            func summary(_ id: String, _ title: String, _ count: Int) -> SessionSummary? {
                JSONValue.object([
                    "id": .string(id), "title": .string(title),
                    "message_count": .number(Double(count)),
                    "last_active": .number(1_700_000_100), "started_at": .number(1_700_000_000),
                    "source": .string("user"),
                ]).decoded(as: SessionSummary.self)
            }
            let list = [summary("uitest-A", "Session A", 6),
                        summary("uitest-B", "Session B long", 40)].compactMap { $0 }
            environment.sessionStore.sessions = list
            environment.connectionStore.phase = .connected
            if let a = list.first { environment.sessionStore.open(a) }  // open A first
            return
        }

        // "demo" — curated, presentable content for the launch video: a power
        // user's drawer + one rich active conversation. No real user data.
        if mode == "demo" {
            func summary(_ id: String, _ title: String, _ count: Int, _ ago: Double) -> SessionSummary? {
                JSONValue.object([
                    "id": .string(id), "title": .string(title),
                    "message_count": .number(Double(count)),
                    "last_active": .number(1_700_000_000 - ago),
                    "started_at": .number(1_700_000_000 - ago - 1000),
                    "source": .string("user"),
                ]).decoded(as: SessionSummary.self)
            }
            let list = [
                summary("demo-1", "Deploy health check", 4, 60),
                summary("demo-2", "Refactor the auth module", 22, 3600),
                summary("demo-3", "Tokyo trip — 5-day itinerary", 16, 7200),
                summary("demo-4", "Fix the flaky websocket test", 31, 14400),
                summary("demo-5", "Draft replies to investor emails", 12, 28800),
                summary("demo-6", "Morning brief", 8, 86400),
            ].compactMap { $0 }
            let convo: [ChatMessage] = [
                ChatMessage(role: .user, text: "Is the staging deploy healthy? Anything broken?"),
                ChatMessage(
                    role: .assistant,
                    text: "Checking the last run and the gateway now.\n\nCI is green on "
                        + "main — build #4821 passed 8 minutes ago. But staging is returning "
                        + "502s: the last deploy left a worker wedged at 99% CPU. A clean "
                        + "restart of staging-gateway will clear it.\n\nWant me to restart it?"),
            ]
            environment.sessionStore.sessions = list
            environment.sessionStore.activeStoredId = "demo-1"
            environment.connectionStore.phase = .connected
            environment.chatStore.debugSeedTranscript(convo)
            return
        }

        environment.sessionStore.activeStoredId = "uitest-\(mode)"
        // Seed TIMING (scroll-race verification):
        //  • "long"/"short" — synchronous: content present at first layout.
        //  • "asynclong"    — ~1ms deferred: mimics the P3 cache actor-hop seed
        //    (content arrives ~1 runloop after the ScrollView appears).
        //  • "netlong"      — ~250ms deferred: mimics today's network seed, to
        //    REPRODUCE the open-on-newest race the cache is meant to fix.
        // The session+connection are set synchronously so ChatView renders an
        // empty transcript first, then the deferred seed lands — exactly the real
        // open ordering.
        let delayMs: UInt64 = mode == "netlong" ? 250 : (mode.hasPrefix("async") ? 1 : 0)
        if delayMs == 0 {
            environment.chatStore.debugSeedTranscript(seeded)
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                environment.chatStore.debugSeedTranscript(seeded)
            }
        }
    }
}
#endif
