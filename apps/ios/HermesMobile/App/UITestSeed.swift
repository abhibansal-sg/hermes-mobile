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
///
/// ROUND-2 stress modes (measurement-first, DEBUG-only, no network):
/// - `stream`: seed 10 messages then drive the REAL streaming path with
///   markdown+code chunks at ~40ms cadence for ~30s — the streaming-jitter repro.
/// - `heavy`: a static 60-message transcript of heavy markdown/code rows — the
///   flick-scroll cost repro.
/// - `shrinkland`: land tall content, then re-seed shorter content ~1s later so
///   contentSize drops below the resting offset — the FIX A blank-page repro.
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

        // ── ROUND-2 STRESS MODES (measurement-first) ──────────────────────────
        // These reproduce the DEVICE costs the simulator masked: per-flush
        // re-segmentation + markdown rebuilds during streaming, heavy-row scroll
        // cost, and the post-disarm row-shrink that strands the viewport (FIX A).

        // "stream" — seed a short transcript then drive the REAL streaming path
        // (debugInjectDelta → handle(event:) → flushBuffers → mutateStreaming) by
        // appending markdown+code-heavy content in ~40ms-cadence chunks for ~30s
        // to a growing assistant message. This is the streaming-jitter repro.
        if mode == "stream" {
            var base: [ChatMessage] = []
            for i in 0..<10 {
                let isUser = i.isMultiple(of: 2)
                base.append(ChatMessage(
                    role: isUser ? .user : .assistant,
                    text: isUser
                        ? "Stress prompt #\(i + 1) — keep streaming markdown and code."
                        : "Prior reply #\(i + 1). Lorem ipsum dolor sit amet."))
            }
            environment.sessionStore.activeStoredId = "uitest-stream"
            environment.chatStore.debugSeedTranscript(base)
            // Append a user turn, then drip the assistant reply through the real
            // delta path. ~40ms cadence × ~750 chunks ≈ 30s of streaming.
            environment.chatStore.debugSeedTranscript(base + [
                ChatMessage(role: .user, text: "Now write a long markdown+code answer."),
            ])
            Task { @MainActor in
                let chunks = Self.streamChunks(count: 750)
                for chunk in chunks {
                    try? await Task.sleep(nanoseconds: 40_000_000)  // 40ms cadence
                    environment.chatStore.debugInjectDelta(chunk)
                }
                environment.chatStore.debugCompleteStream()
            }
            return
        }

        // "heavy" — a static 60-message transcript of HEAVY rows (long markdown
        // with headers/lists/inline code, multi-line fenced code blocks, long
        // paragraphs) for flick-scroll cost measurement. Fully laid-out at seed.
        if mode == "heavy" {
            var heavy: [ChatMessage] = []
            for i in 0..<60 {
                let isUser = i.isMultiple(of: 2)
                if isUser {
                    heavy.append(ChatMessage(
                        role: .user,
                        text: "Heavy prompt #\(i + 1) — explain \(Self.heavyTopics[i % Self.heavyTopics.count]) in depth."))
                } else {
                    heavy.append(ChatMessage(role: .assistant, text: Self.heavyReply(i + 1)))
                }
            }
            environment.sessionStore.activeStoredId = "uitest-heavy"
            environment.chatStore.debugSeedTranscript(heavy)
            return
        }

        // "shrinkland" — reproduce the post-disarm row SHRINK (FIX A). Seed TALL
        // placeholder content, land at the bottom (latch disarms), then ~1s later
        // re-seed the SAME session with SHORTER content so contentSize drops below
        // the resting offset. BEFORE FIX A: the viewport is stranded past the
        // content edge → blank page, chat above. AFTER: the always-on clamp snaps
        // the offset down to the new ceiling.
        if mode == "shrinkland" {
            var tall: [ChatMessage] = []
            for i in 0..<40 {
                let isUser = i.isMultiple(of: 2)
                tall.append(ChatMessage(
                    role: isUser ? .user : .assistant,
                    text: isUser
                        ? "Shrink prompt #\(i + 1)"
                        : Self.heavyReply(i + 1)))  // tall multi-line rows
            }
            environment.sessionStore.activeStoredId = "uitest-shrink"
            environment.chatStore.debugSeedTranscript(tall)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // land, then shrink
                // SAME session id (a same-session reconcile, not a switch) so the
                // landing latch has already disarmed — only the always-on clamp can
                // save the offset. Replace with much shorter rows.
                var short: [ChatMessage] = []
                for i in 0..<10 {
                    let isUser = i.isMultiple(of: 2)
                    short.append(ChatMessage(
                        role: isUser ? .user : .assistant,
                        text: isUser ? "Short prompt #\(i + 1)" : "Short reply #\(i + 1)."))
                }
                environment.chatStore.debugSeedTranscript(short)
            }
            return
        }

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

        // "iddrift" — ARCH37 Step 1 risk gate: open a session whose CACHE copy is
        // 1+ rows SHORTER than the NETWORK copy (count drift), so the Phase-2 network
        // seed reconciles a LONGER row set onto the already-landed cache content. With
        // the OLD positional-id scheme this re-keys the whole tail from the divergence
        // → mass remount with new heights AFTER the open parked (the mid-conversation
        // landing root). This verifies the per-session ScrollView identity (.id) +
        // native anchor land on NEWEST despite the re-keyed tail — and (under
        // HERMES_PERF_LOG=1) that the remount hitch is <1 frame and latch/clamp fire
        // toward zero.
        //
        // Faithful repro: OPEN session A (short), then SWITCH to the drift session B
        // — exactly as the device does it (activeStoredId flips, so the per-session
        // `.id` REMOUNTS the ScrollView and `.landOnNewest` arms). On B's open the
        // CACHE copy (34 rows) paints first (Phase-1), then ~600ms later the NETWORK
        // copy (40 rows) reconciles in place (Phase-2). With the OLD positional id +
        // shared ScrollView this lands MID-CONVERSATION (the network grows under a
        // disarmed latch). With Step 1's per-session remount + Step 4's stable wire
        // id, the open is FRESH (.landOnNewest), so the view re-pins through the grow
        // and lands on the NEWEST (#40); the shared wire ids keep the tail identity
        // (no remount of matching rows).
        if mode == "iddrift" {
            func stored(_ role: String, _ text: String, _ i: Int) -> StoredMessage? {
                StoredMessage(json: .object([
                    "role": .string(role),
                    "content": .string(text),
                    "id": .number(Double(i)),                 // stable wire id (Step 4)
                    "timestamp": .number(Double(1_700_000_000 + i)),
                ]))
            }
            func transcript(_ tag: String, _ n: Int) -> [StoredMessage] {
                (0..<n).compactMap { i in
                    stored(i.isMultiple(of: 2) ? "user" : "assistant",
                           "\(tag) message #\(i + 1) — Lorem ipsum dolor sit amet, consectetur "
                           + "adipiscing elit, sed do eiusmod tempor incididunt ut labore et "
                           + "dolore magna aliqua. Ut enim ad minim veniam.",
                           i)
                }
            }
            // Session B cache copy: 34 rows. Network copy: 40 rows (6-row tail drift),
            // sharing wire ids 0..33. The injected transcriptFetch returns the 40-row
            // network copy for B; the 34-row cache copy is painted directly first.
            let bCache = transcript("Drift", 34)
            let bNetwork = transcript("Drift", 40)
            environment.connectionStore.phase = .connected
            // Session A — a short prior session to land on before the switch.
            environment.sessionStore.activeStoredId = "uitest-iddrift-A"
            environment.chatStore.debugSeedTranscript(
                ChatStore.toChatMessages(transcript("A", 6)))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // read A
                // SWITCH to B: flip activeStoredId (the `.id` remount), paint the
                // CACHE copy (Phase 1), reset lastSeeded via the new id so the open
                // classifies .landOnNewest, then grow to the NETWORK copy (Phase 2).
                environment.sessionStore.activeStoredId = "uitest-iddrift-B"
                environment.chatStore.reset()                     // clear A (as open() does)
                environment.chatStore.seed(from: bCache)          // Phase 1 cache paint
                try? await Task.sleep(nanoseconds: 600_000_000)   // network-like delay
                environment.chatStore.seed(from: bNetwork)        // grow 34 → 40, in place
            }
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

    // MARK: - Stress content generators (ROUND-2)

    /// Topics to vary the heavy prompts/replies so segments differ row-to-row
    /// (defeats any accidental whole-transcript content dedup).
    static let heavyTopics = [
        "async streams", "actor isolation", "structured concurrency",
        "value semantics", "the responder chain", "Core Animation",
    ]

    /// A heavy assistant reply: headers, a list, inline code, a long paragraph,
    /// and a multi-line fenced Swift code block — the row shape that costs the
    /// most to segment + markdown-render on device.
    static func heavyReply(_ n: Int) -> String {
        let topic = heavyTopics[n % heavyTopics.count]
        return """
        ## Reply #\(n): \(topic)

        Here is a thorough answer about **\(topic)**. The key points, with some \
        `inline code` and *emphasis*, are below:

        - First, the `Task` runs on the current actor unless detached.
        - Second, a `for await` loop suspends when the buffer is empty.
        - Third, back-pressure must be explicit — `AsyncStream` is unbounded.

        A longer paragraph to force multi-line wrapping and real layout cost: \
        lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod \
        tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim \
        veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip.

        ```swift
        func process(_ events: AsyncStream<Event>) async {
            var budgetStart = ContinuousClock.now
            for await event in events {
                route(event)
                if budgetStart.duration(to: .now) > .milliseconds(8) {
                    await Task.yield()   // give UIKit a runloop turn
                    budgetStart = .now
                }
            }
        }
        ```

        That covers \(topic) — ask if you want the edge cases too.
        """
    }

    /// ~`count` streaming chunks that together build a long markdown+code answer.
    /// Chunks are small (a few words / code tokens) to mimic real token cadence,
    /// and cycle through prose, list items, and fenced code so every flush
    /// re-segments a growing body that contains both prose and code runs.
    static func streamChunks(count: Int) -> [String] {
        var chunks: [String] = []
        let proseWords = [
            "The ", "streaming ", "path ", "must ", "stay ", "smooth ", "even ",
            "while ", "markdown ", "and ", "code ", "render ", "incrementally. ",
        ]
        var i = 0
        while chunks.count < count {
            // Every ~40 chunks, emit a header / list / code-fence boundary so the
            // segmenter has to re-split prose vs code on the growing tail.
            let phase = (chunks.count / 40) % 4
            switch phase {
            case 0:
                chunks.append(proseWords[i % proseWords.count])
            case 1:
                chunks.append(chunks.count % 8 == 0 ? "\n- item " : "point ")
            case 2:
                if chunks.count % 40 == 80 % 40 { chunks.append("\n```swift\n") }
                chunks.append("let x = \(i % 10); ")
            default:
                if chunks.count % 40 == 120 % 40 { chunks.append("\n```\n\n") }
                chunks.append(proseWords[i % proseWords.count])
            }
            i += 1
        }
        return chunks
    }
}
#endif
