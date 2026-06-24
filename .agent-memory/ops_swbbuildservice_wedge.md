---
name: ops_swbbuildservice_wedge
description: Force-killing iOS xcodebuild jobs wedges the session-wide SWBBuildService; symptom = every build hangs at CreateBuildDescription; only reboot/logout clears it.
metadata: 
  node_type: memory
  type: project
  originSessionId: c6271256-6b41-4b30-a2e2-057a9325db34
---

On the Mac Studio (busy multi-agent iOS build host), **force-killing (`SIGKILL`)
`xcodebuild`/`SWBBuildService` mid-build can wedge the session-wide SwiftBuild
service substrate.** Once wedged, EVERY `xcodebuild build`/`archive` on the
machine — across unrelated projects — deadlocks identically and silently.

**Signature (how to recognize it fast, 2026-06-08):**
- Build log stops at `GatherProvisioningInputs` → `CreateBuildDescription` →
  `ExecuteExternalTool swiftc --version` / `clang -dM /dev/null`, then nothing.
- `pgrep -x swift-frontend` = **0** (nothing is compiling anywhere).
- `SWBBuildService` main thread parked in
  `swift_task_asyncMainDrainQueue → CFRunLoopRun → mach_msg`, ~0% CPU, empty
  unified log. xcodebuild parent parked in `waitForBuildWithBuildLog`.
- Confirm machine-wide: sample ANOTHER project's `SWBBuildService` (e.g. the
  `LiveTranslate` translation-app archive) — if it's frozen in the same state,
  it's the session wedge, not your project/code.

**What does NOT fix it (all tested, all failed):** fresh vs warm DerivedData,
restoring standard `$TMPDIR` (Claude Bash sets `TMPDIR=/tmp/claude-501`),
`dangerouslyDisableSandbox`, killing all build processes system-wide, clearing
SourcePackages/build.db-wal locks, killing SourceKit indexers, bouncing
`cfprefsd`/`previewsd`, quitting Simulator. The toolchain itself is FINE —
a direct `swiftc -sdk <simsdk> -c file.swift -o x.o` compiles in <1s.

**ROOT CAUSE — CONFIRMED EXTERNALLY (2026-06-24, manaflow-ai/cmux#2980 + PR#2981):**
**Xcode 26 made `SWBBuildService` a per-user SINGLETON Mach service.** Concurrent
`xcodebuild` invocations each spawn their own `SWBBuildService` child but RACE to
register on the same well-known per-user XPC name; the loser's IPC handshake never
completes and BOTH ends park forever in `mach_msg2_trap` (xcodebuild in
`waitForBuildWithBuildLog:`, the service in `RunLoopExecutor.run`). **`-derivedDataPath`
isolates build OUTPUT but does NOT isolate the daemon** — which is exactly why our
per-worktree DerivedData never prevented the wedge. cmux hit the identical signature
(hang at `CreateBuildDescription`, 0% CPU, even with distinct `-derivedDataPath`) on a
totally different codebase, started after the Xcode-16→26 upgrade. Their fix = a global
`flock` serializing `xcodebuild` — mechanically identical to our `scripts/ios-build.sh`
mutex, confirming our architecture is the right one (their second fix, fetching a
prebuilt framework to avoid a NESTED xcodebuild, is cmux-specific; we have no nested build).

**Xcode 26 actually has ≥2 DISTINCT hang bugs — don't over-unify them (2026-06-24):**
- **(1) Concurrent-registration race (OURS + cmux#2980):** the per-user-singleton race
  above. Triggered by CONCURRENT xcodebuilds; parks EARLY at `CreateBuildDescription`,
  never reaches SUCCEEDED. Fix = serialize (our mutex) + logout/login to recover. This is
  the PRIMARY trigger for our case.
- **(2) Pipe-not-closing AFTER success (react-native-community/cli#2768):** on Xcode 26.2+
  / macOS 26.3, xcodebuild/SWBBuildService keeps its pipes open AFTER `BUILD SUCCEEDED`,
  so the close event never fires and the process hangs at the END of an otherwise-successful
  build. RN's workaround: detect `BUILD SUCCEEDED` in the log and proactively reap the
  process instead of waiting for it to exit. (We adopted this in the wrapper — see below.)
  This RESURRECTS the pipe-deadlock angle as a REAL but SEPARATE failure mode.
- **Older note (2026-06-08):** a clang `-dM` pipe-buffer deadlock (~16358 B vs 16384 B pipe,
  read-ends undrained) — plausibly a contributing surface to (1)/(2), but NOT the headline
  cause of the concurrent case. Tell the two apart by WHERE it parks: `CreateBuildDescription`
  (never compiled) = (1); after `BUILD SUCCEEDED` (built fine, won't exit) = (2).

**The ONLY reliable fix:** reboot (cleanest) or logout/login — resets the
launchd user-session substrate. NOT fixed by: QoS unthrottle (`taskpolicy -B`),
clean env (`env -i`), killing stale Mach registrations (none squatted), or
resource limits (all had headroom). The live dashboard (`ai.hermes.dashboard`,
launchd KeepAlive) auto-restarts on boot, so a reboot is clean for it. The
USER runs the reboot.

**Prevention:** never leave a build background task unreaped across turns, and
prefer letting builds finish or time out gracefully over `kill -9`. A hard-killed
build is "patient zero" for this wedge.

**Prevention by construction (2026-06-09):** build the iOS app ONLY through
`scripts/ios-build.sh` (committed to the repo). It holds a machine-global mutex
(only ONE iOS build at a time across ALL Conductor worktrees), auto-injects
per-worktree DerivedData, and reaps a hung build with SIGTERM (NEVER -9). It also
pre-flights the wedge signature (SWBBuildService up + 0 swift-frontend) and warns
to reboot rather than stack another frozen build. In Conductor's parallel-worktree
model the concurrent-build trigger is easy to hit, so this wrapper is the standing
guard — don't call `xcodebuild` for the app directly. See [[feedback_no_computer_use_for_sim]],
[[project_hermes_mobile]], [[project_translation_app]].

**MUTEX GAP — `xcodebuildmcp` bypasses the guard (recurred 2026-06-12):** During
the round-2 iOS smoothness pass the wedge recurred even though my build went
through `scripts/ios-build.sh`. Root: the script's mutex only serializes builds
*that go through the script*. Other Conductor worktrees on this repo
(`abh-88-depatch-w1`, `phase2-upstream-rebase`, `valencia`) had idle
`xcodebuildmcp@latest mcp` servers (Codex-CLI MCP build servers) running; one of
those (or Xcode.app) can issue a **direct `xcodebuild`** that races a script-driven
build and wedges the shared SWBBuildService session-wide. Signature was textbook:
two consecutive clean builds (a pre-existing one + my fresh retry) BOTH parked at
`CreateBuildDescription` with `swift-frontend`=0, SWBBuildService at 0% CPU, 0
compiles, for >4 min each. Both reaped cleanly via SIGTERM (TaskStop, never -9);
the live dashboard on :9119 stayed HTTP-200 throughout. **Lesson:** the mutex is
necessary but NOT sufficient — when ANY tool can call `xcodebuild` directly
(xcodebuildmcp, a Codex session, Xcode.app, even SourceKit background indexing), the
only complete prevention is to ensure no other worktree/agent builds the app
concurrently, OR to route every iOS build (incl. MCP servers) through the wrapper.

**RECURRED 2026-06-24 on a SINGLE wrapper-driven archive (build 52):** the archive went
through `scripts/ios-build.sh` yet still wedged (20 min at `CreateBuildDescription`,
xcodebuild 0% CPU, 0 swift-frontend, log frozen, but the toolchain probes ran INSTANTLY
standalone). Confirms the per-user daemon was poisoned by something OUTSIDE the mutex
BEFORE our build started (xcodebuildmcp from a sibling worktree and/or SourceKit — the
stale "Cannot find type" SourceKit diagnostics earlier in the session were an early tell
the build service was already unhappy). Reaped with SIGTERM (never -9). **Recovery: a
logout/login is enough (resets the per-user SWBBuildService); a full reboot is NOT
required** (lighter than the 2026-06-08 reboot).

**WRAPPER HARDENED 2026-06-24 (closes the detection gap):** `scripts/ios-build.sh` now
(1) **pre-flight ABORTs** (exit 75) when the wedge signature is already present instead
of only warning — don't stack a build on a poisoned daemon (override
`HERMES_BUILD_ALLOW_WEDGED=1`); (2) warns when a **foreign xcodebuild** is already
running (the concurrency-race trigger); (3) **EARLY WEDGE DETECT** in the watchdog —
after `HERMES_WEDGE_GRACE` (240s) it SIGTERM-reaps a build that is parked with 0
swift-frontend + no recent `.o` + idle xcodebuild + log still at CreateBuildDescription,
and returns **exit 75** (distinct from a normal build failure) with a "log out/in" message.
So a wedge now self-detects at ~270s instead of running out the full `HERMES_BUILD_TIMEOUT`
(the prior watchdog only acted at the hard timeout — why the build-52 wedge sat 20 min in
the background). The governor loop can branch on rc=75 ("needs human logout/login") vs a
real failure.
