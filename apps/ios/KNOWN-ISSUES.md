# HermesMobile — Known issues (first public beta)

Honest list of current limitations + rough edges for the external TestFlight
beta. Source the "What to Test" notes and the public repo's issues section from
this file. Each item links to its tracker where one exists.

## Setup / connectivity

- **Desktop must share the same gateway as the phone (ABH-158 family / "remote
  mode").** The iOS app pairs with ONE gateway (your dashboard gateway). It sees
  the Hermes *desktop's* sessions only when the desktop is **attached to that same
  shared gateway**. In the desktop's default "local" mode it runs its own isolated
  gateway the phone never sees. Workaround: run the desktop attached to the shared
  gateway (set `HERMES_TUI_GATEWAY_URL=ws://127.0.0.1:9119/api/ws?token=…`). A
  one-step "always share" option is planned.
- **Reconnect after a long background can stick on "Reconnecting…".** After the
  app has been backgrounded for a long time, foregrounding occasionally stays on
  "Reconnecting…"; **force-quit + reopen** recovers. On watch — not currently
  reproducing after the build-47/48 hydration fixes. (ABH-158)
- **Tailnet reachability.** The phone must be able to reach your gateway (same LAN
  or Tailscale). A `*.ts.net` connection failure surfaces an "Is Tailscale
  connected?" hint.

## Notifications

- **In-app approvals & clarifications always work** — when the agent needs you, it
  surfaces live in the app, on any gateway.
- **Background push (notifications when the app is closed) needs the app's own APNs
  signing key, which only the app's publisher holds.** So on the **TestFlight
  build**, background push (long-turn-done / approval-while-away) and *remote* Live
  Activity updates are **not available from your self-hosted gateway** — you still
  get live chat, sync, in-app approvals, and the **on-device** Live Activity timer.
  If you **build the app yourself** with your own Apple Developer team + APNs key,
  set it on the gateway (`HERMES_APNS_*`) and background push works. (A hosted push
  relay that enables push for TestFlight testers is on the roadmap.)
- **Enabling:** Settings → Notifications → toggle on → grant the iOS prompt.
  (Builds ≤48 had the toggle stuck disabled; fixed in 49+.)

## UI polish (cosmetic, self-correcting)

- **Drawer row can briefly flicker during a very long silent turn.** If an agent
  turn goes >10s with no streamed output and the session list refreshes in that
  gap, the row can drop a slot then pop back; it self-corrects at turn end.
  (ABH-160 follow-up)
- **Accessibility pass in progress.** A handful of controls use fixed font sizes
  / lack VoiceOver labels; a Dynamic Type + contrast sweep is underway.

## Not yet in this beta

- App Store distribution (this is an external TestFlight beta).
- A hosted/cloud gateway — the app requires your own `hermes-agent` gateway with
  the HermesMobile plugin (see the setup guide).
