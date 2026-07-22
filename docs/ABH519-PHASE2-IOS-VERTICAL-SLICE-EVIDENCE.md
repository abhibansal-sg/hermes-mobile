# ABH-519 Phase 2 — iOS stock-protocol vertical-slice evidence

**Captured:** 2026-07-22 19:03–19:12 +08:00

**Device:** physical iPhone Air (`iPhone18,4`), UDID ending `C0E7`

**Branch:** `codex/abh-519-v019-phase2-ios-vertical-slice`

**Base:** Phase 1 merge `784b9eac6c8fe8038ae3b691f9d954985c74b94c`

## Isolated route

The app was normally launched (no process environment overrides) with its existing
transport selection persisted as `gatewayDirect`. The existing relay URL override selected
the transparent proxy at `192.168.4.92:8795`; that proxy forwarded to the isolated stock
gateway at `127.0.0.1:9135`. Live ports 8788 and 9119 were not used by the valid run.

Before the valid run, one attempt was rejected as evidence: reopening the app had dropped a
temporary launch environment and restored the persisted legacy relay selection on port 8788,
while the cache identity remained the isolated gateway on port 9135. That mixed route exactly
reproduced replies under Work and user-only cache rows. The persisted settings were corrected,
the app was normally relaunched, and an established phone -> 8795 -> 9135 connection was
observed before sending the accepted prompts.

## New-chat and disk-repaint result

The phone created three sessions through stock `session.create` + `prompt.submit`. The two
acceptance prompts completed as standalone assistant messages:

| Stored session | Gateway messages | Settled assistant |
|---|---:|---|
| `20260722_190434_0af071` | 2 | `P2-OK` |
| `20260722_190505_91d3ab` | 2 | `P2-OK` |

After switching sessions and force-closing/reopening the app, the physical-device GRDB copy
contained the same two user/assistant pairs in `message_row_cache`, keyed by those stored IDs,
with wire IDs 1–4. `session_cache.messageCount` was 2 for each row and
`last_opened_session` pointed to the selected stored ID. The owner confirmed both replies
remained normal assistant bubbles rather than Work content.

## Drive-versus-watch result

A second stock client created runtime `ada344d4` / stored session
`20260722_190718_646900`, submitted a 90-second tool turn, and retained its socket. Independent
`session.active_list` calls reported the same runtime as `working` before and after the phone
opened **Desktop Watch Gate**. The phone did not issue a stealing resume: no replacement runtime
appeared and no 4007 occurred. The original client received authoritative
`message.complete: WATCH-DONE`.

After completion, switching away and back on the phone painted `WATCH-DONE`. The pulled device
cache held the complete four-row transcript under the stored ID: user (wire 7), assistant tool
call (8), tool result (9), and assistant `WATCH-DONE` (10). The owner confirmed the completion
was visible.

## Automated gates

- iOS simulator contract slice: 183 tests, 0 failures.
- Migrated device-shaped cache coverage: existing `CacheMigrationV3RepairTests` build-116
  populated database reopen + draft-born write passed in that slice.
- External real-gateway stock proxy proof: 1 passed against isolated gateway 9130+.
- Physical build used `scripts/ios-build.sh`; build and install succeeded.
- Isolated gateway logs: zero `4007`, parse errors, dispatch crashes, or send failures during
  the accepted window.

## Evidence locations

Sanitized physical cache copies and command outputs are outside the repository at:

`/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver/abh519-phase2-pass-20260722/`

The initial rejected mixed-route snapshot is retained separately at:

`/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver/abh519-phase2-fail-20260722/`

No credentials or prompt secrets are recorded in this document.
