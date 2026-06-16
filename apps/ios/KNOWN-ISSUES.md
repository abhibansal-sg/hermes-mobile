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

- **You must grant the iOS permission once.** Open **Settings → Notifications** in
  the app and toggle it on to trigger the system permission prompt. (Build ≤48 had
  a bug where the toggle was stuck disabled; fixed in the next build.)
- Push fires for: approvals, clarifications, and long turns finishing while
  backgrounded — per-event toggles are in Settings.

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
