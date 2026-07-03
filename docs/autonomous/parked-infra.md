# Parked Infrastructure — do NOT build on these until unblocked

Machine-readable map for the refiner + orchestrator. Before promoting or
dispatching an issue, check whether its VALUE depends on anything listed here.
If it does: PARK it (label `loop:parked-low-value`, comment the dependency),
do not build. Building features on parked infrastructure is wasted provider
spend — the work ships but delivers nothing to Abhi's phone.

Maintenance: the orchestrator removes an entry (and un-parks its dependents)
when the blocking issue merges. Abhi can unblock any entry by commenting on
the blocking issue.

| Infra | Blocked on | What's parked with it | Working alternative |
|---|---|---|---|
| Relay push path (relay server, relay test-push, relay enrollment) | ABH-202 — public relay server deployment (external infra, Abhi approval) | Any feature routing through `relay_client`; relay settings UI polish; relay test-push fixes | DIRECT APNs (gateway `.p8` + HERMES_APNS_*) — already live and the real path |
| Reverse tunnel (Tailscale-killer, phone→gateway without Tailscale) | ABH-202 (same relay server) | Tunnel status UI, tunnel reconnect logic | Tailscale for interactive; direct APNs for push |
| External TestFlight / App Store surface | Abhi's explicit gate (never autonomous) | Public-beta onboarding flows, App Store metadata work | Internal TestFlight |

Rules of thumb:
- "Fix the Test Push button" class: the fix is to make the button test the path
  the gateway ACTUALLY uses (direct APNs), not to make relay work. Re-spec such
  issues toward the working path instead of parking, when possible.
- When a scout files an issue about a parked surface, the refiner comments the
  dependency + parks — it does not silently drop it (parked is reversible).
