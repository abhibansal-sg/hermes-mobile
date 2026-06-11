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

**Exact mechanism (traced 2026-06-08):** During `CreateBuildDescription`,
SWBBuildService spawns clang capability probes (`clang -v -E -dM … -c /dev/null`).
The `-dM` output is ~16358 bytes vs a 16384-byte pipe buffer (razor's edge).
clang blocks in `write()` to its stdout/stderr pipe; SWBBuildService HOLDS the
read-ends (its fd 6/12 ↔ clang fd 1/2) but never drains them — its Swift
concurrency cooperative pool won't spawn worker threads (process shows only 2
threads, parked in `swift_task_asyncMainDrainQueue → CFRunLoopRun → mach_msg`).
Classic pipe deadlock; happens in a FRESH SWBBuildService every time.

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
