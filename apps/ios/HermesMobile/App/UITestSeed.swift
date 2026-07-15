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

    /// STR-459/STR-462: DEBUG/UITest-only navigation seed. When the launch
    /// environment carries the exact value `HERMES_UITEST_PANEL=gateway`, the
    /// shell (``RootView``'s `SplitLayout`/`CompactLayout`) cold-launches
    /// straight into the Settings sheet's Gateway Status panel — no manual
    /// taps — so a UI test can assert that panel deterministically. Any other
    /// value (or the variable's absence) leaves navigation untouched.
    static var requestedPanel: String? {
        ProcessInfo.processInfo.environment["HERMES_UITEST_PANEL"] == "gateway" ? "gateway" : nil
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

        // Deterministic markdown-table evidence fixtures for the cell-wrapping
        // regression. Each mode paints one production MessageBubble offline so
        // simulator screenshots exercise the real parser and table view.
        if mode.hasPrefix("tablewrap") {
            let markdown: String
            switch mode {
            case "tablewrap-v4-mixed":
                markdown = """
                | Detail | State | Retry |
                | --- | --- | --- |
                | This deliberately long cell wraps across multiple lines while its short neighbors remain single-line. | ✅ done | yes |
                | **Inline bold content also participates in the measured width and still wraps without an ellipsis.** | ready | no |
                """
            case "tablewrap-v4-token":
                markdown = """
                | Setting | Value | Result |
                | --- | --- | --- |
                | Retry guard | `consecutive_failures + max_retries` | ✅ stable |
                """
            case "tablewrap-v4-heights":
                markdown = """
                | Detail | State |
                | --- | --- |
                | Short | ready |
                | This long detail wraps evenly across several lines in its cell. | This long state also wraps evenly across several lines in its cell. |
                """
            case "tablewrap-v4-parity":
                markdown = """
                | Check | iOS | Desktop | Status |
                | --- | --- | --- | --- |
                | Short cells | ✅ done | ✅ done | yes |
                | Failure path | ❌ blocked | ❌ blocked | no |
                | Rich runs | **✅ bold** | `❌ code` | ready |
                """
            case "tablewrap-a":
                markdown = """
                | Link | Block kind | Dependency rule | Priority |
                | --- | --- | --- | ---: |
                | task_links | task_links + typed block_kind (dependency never sits in blocked) | dependency never sits in blocked; task_links stores the typed relation only | (priority integer preserves ordering across graph updates) |
                """
            case "tablewrap-b":
                let longCell = String(String(
                    repeating: "Every character in this three-hundred-character table fixture must remain visible and wrap naturally inside the fixed column width. ",
                    count: 3
                ).prefix(294)) + " END-B"
                markdown = """
                | 300-character cell | Status |
                | --- | ---: |
                | \(longCell) | Complete |
                """
            default:
                markdown = """
                | Key | Value |
                | --- | ---: |
                | Mode | Ready |
                | Count | 42 |
                """
            }
            environment.sessionStore.activeStoredId = "uitest-\(mode)"
            environment.chatStore.debugSeedTranscript([
                ChatMessage(role: .assistant, text: markdown),
            ])
            return
        }

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

        // "thinking" — STR-1062 evidence seed (no gateway): renders the clean
        // thinking block in BOTH states for sim-scoped capture. Seeds a SETTLED
        // assistant turn with reasoning + a stamped `reasoningElapsed` (so it
        // collapses to the quiet "Thought for 6s" label), then drives the REAL
        // streaming reasoning path (`debugInjectReasoningDelta` → thinkingBuffer →
        // flushBuffers → appendReasoningDelta) so a LIVE assistant turn pulses with
        // an inline timer and a tail-scrolled faded body, then settles. Proves the
        // contract: a calm italic label + scroll body, NO brain glyph / kaomoji /
        // spinner anywhere in the thinking block. Never compiled into Release.
        if mode == "thinking" {
            let settledReasoning = """
            First I checked the last CI run on main — it passed eight minutes ago.
            Then I probed staging and saw 502s: the deploy left a worker wedged at \
            high CPU. A clean restart of staging-gateway should clear it.
            """
            let base: [ChatMessage] = [
                ChatMessage(role: .user, text: "Is the staging deploy healthy?"),
                ChatMessage(
                    role: .assistant,
                    text: "Staging was returning 502s from a wedged worker — a clean restart of staging-gateway clears it.",
                    thinking: settledReasoning,
                    reasoningElapsed: 6
                ),
                ChatMessage(role: .user, text: "Walk me through how you'd debug a flaky websocket test."),
            ]
            environment.connectionStore.phase = .connected
            environment.sessionStore.activeStoredId = "uitest-thinking"
            environment.chatStore.debugSeedTranscript(base)
            Task { @MainActor in
                // Drip reasoning through the real reasoning.delta path so the live
                // thinking row pulses with a timer and a tail-scrolled faded body.
                let steps = Self.thinkingStreamSteps()
                for step in steps {
                    try? await Task.sleep(nanoseconds: 350_000_000)  // ~350ms cadence
                    environment.chatStore.debugInjectReasoningDelta(step)
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)  // let the timer read a few seconds
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

        // "drawerstorm" — STR-1012 regression seed for compact drawer row-tap
        // storms. It starts on Storm 1 with a populated drawer, then delays the
        // real open seed so non-active taps prove the STR-1007 deadline path while
        // active re-taps prove the synchronous close path.
        if mode == "drawerstorm" {
            func stored(_ role: String, _ text: String, _ i: Int) -> StoredMessage? {
                StoredMessage(json: .object([
                    "role": .string(role),
                    "content": .string(text),
                    "id": .number(Double(i)),
                    "timestamp": .number(Double(1_700_010_000 + i)),
                ]))
            }
            func transcript(_ tag: String) -> [StoredMessage] {
                (0..<8).compactMap { i in
                    stored(
                        i.isMultiple(of: 2) ? "user" : "assistant",
                        "\(tag) transcript row #\(i + 1)",
                        i
                    )
                }
            }
            func summary(_ id: String, _ title: String, _ count: Int, _ ago: Double) -> SessionSummary? {
                JSONValue.object([
                    "id": .string(id),
                    "title": .string(title),
                    "message_count": .number(Double(count)),
                    "last_active": .number(1_700_010_000 - ago),
                    "started_at": .number(1_700_010_000 - ago - 100),
                    "source": .string("user"),
                ]).decoded(as: SessionSummary.self)
            }

            let list = (1...6).compactMap { index in
                summary("storm-\(index)", "Storm \(index)", 8 + index, Double(index * 60))
            }
            environment.connectionStore.phase = .connected
            environment.sessionStore.sessions = list
            environment.sessionStore.activeStoredId = "storm-1"
            environment.chatStore.debugSeedTranscript(ChatStore.toChatMessages(transcript("Storm 1")))
            environment.sessionStore.beforeOpenSeedForTesting = {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            environment.sessionStore.resumeRPC = { storedId, _ in
                guard let result = JSONValue.object([
                    "session_id": .string("runtime-\(storedId)"),
                    "stored_session_id": .string(storedId),
                    "message_count": .number(8),
                    "info": .object([
                        "running": .bool(false),
                        "lazy": .bool(false),
                    ]),
                ]).decoded(as: SessionOpenResult.self) else {
                    throw URLError(.cannotDecodeContentData)
                }
                return result
            }
            environment.sessionStore.transcriptFetch = { id in
                return transcript(id.capitalized)
            }
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

        // "multiprofile" — DEBUG seed for the All Profiles drawer (STR-1022):
        // 3 profiles (default + work + personal), each with multiple sessions,
        // so the collapsed-by-default + few-recent preview + expand flow is
        // demonstrable without a live multi-profile gateway. Forces the
        // capability + profile list through DEBUG seams, sets activeProfile to
        // the aggregate "all" scope, and injects transcriptFetch so tapping a
        // row opens a transcript without a network call.
        if mode == "multiprofile" {
            let profileList = [
                ProfileSummary(name: "default", isDefault: true, description: nil),
                ProfileSummary(name: "work", isDefault: false, description: nil),
                ProfileSummary(name: "personal", isDefault: false, description: nil),
            ]
            environment.connectionStore.capabilities._seedProfilesCapabilityForTesting(.available)
            environment.sessionStore._seedProfilesForTesting(profileList)
            environment.sessionStore.activeProfile = DefaultsKeys.allProfilesScope

            func summary(_ id: String, _ title: String, _ count: Int, _ ago: Double, _ profile: String) -> SessionSummary? {
                JSONValue.object([
                    "id": .string(id), "title": .string(title),
                    "message_count": .number(Double(count)),
                    "last_active": .number(1_700_000_000 - ago),
                    "started_at": .number(1_700_000_000 - ago - 1000),
                    "source": .string("user"),
                    "profile": .string(profile),
                ]).decoded(as: SessionSummary.self)
            }

            let list: [SessionSummary] = [
                // default profile — 5 sessions (expanded by default)
                summary("mp-d1", "Deploy health check", 4, 60, "default"),
                summary("mp-d2", "Refactor the auth module", 22, 3600, "default"),
                summary("mp-d3", "Tokyo trip — 5-day itinerary", 16, 7200, "default"),
                summary("mp-d4", "Fix the flaky websocket test", 31, 14400, "default"),
                summary("mp-d5", "Morning brief", 8, 86400, "default"),
                // work profile — 4 sessions (collapsed by default)
                summary("mp-w1", "Q3 roadmap planning", 14, 120, "work"),
                summary("mp-w2", "API gateway migration", 28, 1800, "work"),
                summary("mp-w3", "Customer onboarding flow", 9, 7200, "work"),
                summary("mp-w4", "Security audit prep", 19, 21600, "work"),
                // personal profile — 3 sessions (collapsed by default)
                summary("mp-p1", "Weekend hiking routes", 6, 600, "personal"),
                summary("mp-p2", "Recipe collection", 11, 5400, "personal"),
                summary("mp-p3", "Book recommendations", 7, 36000, "personal"),
            ].compactMap { $0 }

            environment.sessionStore.sessions = list
            environment.sessionStore.activeStoredId = "mp-d1"
            environment.connectionStore.phase = .connected

            // Inject transcriptFetch so tapping a session row opens a
            // transcript without a gateway call.
            environment.sessionStore.transcriptFetch = { id in
                try? await Task.sleep(nanoseconds: 150_000_000)
                func stored(_ role: String, _ text: String, _ i: Int) -> StoredMessage? {
                    StoredMessage(json: .object([
                        "role": .string(role),
                        "content": .string(text),
                        "id": .number(Double(i)),
                        "timestamp": .number(Double(1_700_000_000 + i)),
                    ]))
                }
                return (0..<4).compactMap { i in
                    stored(i.isMultiple(of: 2) ? "user" : "assistant",
                           "Seed message #\(i + 1) for \(id)", i)
                }
            }

            // Seed the active session's transcript so ChatView renders.
            let convo: [ChatMessage] = [
                ChatMessage(role: .user, text: "Is the staging deploy healthy?"),
                ChatMessage(role: .assistant,
                            text: "CI is green on main. Staging is returning 502s "
                                + "from a wedged worker. A restart will clear it."),
            ]
            environment.chatStore.debugSeedTranscript(convo)
            return
        }

        // "toast-stale-resurrect" — STR-136 Finding A evidence: seed an error into
        // `ChatStore.lastError` (as a failed send would), let its toast auto-dismiss
        // after 4s, then remount `ChatView` the same way an iPad Split View / Stage
        // Manager / Slide Over resize does — SplitLayout/CompactLayout both gate
        // ChatView on `activeStoredId`, so flipping it to nil and back tears down
        // and recreates the view exactly as swapping between the two layouts would,
        // without needing OS-level window-resize automation (which XCUITest cannot
        // drive deterministically on the simulator). Post-fix, `chatStore.lastError`
        // is cleared when the toast dismisses, so the remount's `onAppear` has
        // nothing stale to re-present.
        if mode == "toast-stale-resurrect" {
            let sessionId = "uitest-toast-resurrect"
            environment.connectionStore.phase = .connected
            environment.sessionStore.activeStoredId = sessionId
            environment.chatStore.debugSeedTranscript([
                ChatMessage(role: .user, text: "Trigger a failed send for STR-136 toast evidence."),
            ])
            environment.chatStore.lastError = "Seeded failure for STR-136 toast evidence"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_500_000_000)  // past the 4s auto-dismiss
                environment.sessionStore.activeStoredId = nil       // unmount ChatView
                try? await Task.sleep(nanoseconds: 300_000_000)
                environment.sessionStore.activeStoredId = sessionId // remount ChatView
            }
            return
        }

        // "offline-no-session" — STR-136 Finding B evidence: a verified connection
        // (so RootView's `.offline` gate shows the shell, not WelcomeView) that
        // drops offline with NO active session/draft selected — the empty-detail
        // placeholder branch. Post-fix, `ConnectionStatusBanner` is hoisted onto
        // the shell container (SplitLayout) / mounted on the placeholder
        // (CompactLayout) so it renders in this branch too, not just the chat one.
        if mode == "offline-no-session" {
            environment.connectionStore._seedConnectedForTesting(
                serverURL: "https://uitest.invalid", token: "uitest-token")
            // `_seedConnectedForTesting` never opens a real socket, so the app's
            // own `handleScenePhase(.active)` (ConnectionStore.swift:1585) — which
            // fires naturally as the app foregrounds at launch — reads the
            // never-opened client as a dead socket and starts a REAL reconnect
            // loop against the fake serverURL below. That loop's own
            // `self.phase = .reconnecting(attempt:)` assignments race the
            // `.offline` phase this seed sets, clobbering it within ~1s (observed:
            // the banner settles on "reconnecting" text, not "offline"). Forcing
            // `clientStateOverrideForScenePhase = .open` alone is NOT enough: with
            // a non-dead socket, `handleScenePhase` falls into its
            // `case .connected = self.phase` branch instead (phase is still
            // `.connected` from the seed above) and runs a liveness probe — which,
            // with no real transport, still fails and calls `startReconnectLoop()`
            // itself (ConnectionStore.swift:1672). Both seams must be stubbed
            // together so `handleScenePhase` takes neither reconnect path.
            environment.connectionStore.clientStateOverrideForScenePhase = .open
            environment.connectionStore.probeLivenessRPC = { _ in true }
            environment.sessionStore.activeStoredId = nil
            environment.sessionStore.sessions = []
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                environment.connectionStore.phase = .offline("Simulated outage for STR-136 evidence")
            }
            return
        }

        // "mdimage" — STR-695/STR-1399 acceptance seed for inline markdown
        // images. A remote PNG exercises AsyncImage while the inline data URL
        // keeps the UI test deterministic without network access.
        if mode == "mdimage" {
            let dataPNG = "data:image/png;base64,"
                + "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+"
                + "AAAAEklEQVR42mP4z8DwHxkzkC4AADxAH+Ea86VIAAAAAElFTkSuQmCC"
            let remotePNG =
                "https://raw.githubusercontent.com/jdecked/twemoji/main/assets/72x72/1f4f7.png"
            let prose = "Here is the render check. before "
                + "![remote camera](\(remotePNG)) middle "
                + "![inline pixel](\(dataPNG)) after — the prose continues past both "
                + "images so paragraph/image/paragraph ordering is exercised."
            environment.sessionStore.activeStoredId = "uitest-mdimage"
            environment.connectionStore.phase = .connected
            environment.chatStore.debugSeedTranscript([
                ChatMessage(role: .user, text: "Show me the two inline images."),
                ChatMessage(role: .assistant, text: prose),
            ])
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

    /// Reasoning chunks for the `thinking` evidence seed: plausible debugging
    /// steps emitted one per ~350ms so the live thinking row shows a streaming,
    /// tail-scrolled chain of thought (each step refreshes the active-step label
    /// and grows the faded body) before `debugCompleteStream` settles it.
    static func thinkingStreamSteps() -> [String] {
        [
            "I'd start by making the flake reproducible — run the test in a loop ",
            "until it fails, since a one-off pass proves nothing. ",
            "Next, isolate whether it's timing or state: add a deterministic clock ",
            "and reset all shared fixtures between runs. ",
            "Websockets in particular leak state across tests if the server ",
            "isn't torn down — check that the connection is fully closed ",
            "and the receive loop is cancelled, not just abandoned. ",
            "Then look at ordering: parallel test runners can interleave ",
            "handshakes on the same port, which reads as a flaky connect. ",
            "Pin the assertions to the framed messages, never to wall-clock, ",
            "and assert the close frame is exchanged before teardown. ",
            "Finally, run it under repeats with thread sanitizer to catch ",
            "any concurrent access the timing papered over. ",
        ]
    }
}
#endif
