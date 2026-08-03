# Hermes Mobile — known limits

This file records current product boundaries, not historical implementation plans.

- **One gateway is one session universe.** The phone and Desktop show the same
  sessions only when both connect to the same Hermes gateway.
- **Foreground chat needs only the stock gateway.** APNs notifications and remote
  Live Activity updates additionally require the Hermes Mobile notification
  plugin and its push-relay credentials. The retired chat transport relay is not
  required.
- **A killed app cannot watch a stock gateway continuously.** On launch or
  foreground, the app paints its local cache first and then reconciles with the
  gateway's session list, transcript, and active-session snapshot.
- **Ambiguous delivery depends on prompt receipts.** If a connection drops after
  the gateway accepted a prompt but before the phone received the acknowledgement,
  a gateway without the plugin's receipt seam cannot prove whether retrying is
  safe. The durable outbox therefore guarantees delivery attempts, not agent
  completion.
- **Connectivity remains network-dependent.** A self-hosted gateway must be
  reachable from the phone over HTTPS (for example through LAN or Tailscale).
  Brief network loss may show Reconnecting while queued sends wait for recovery.

Release acceptance is tracked through source tests, GitHub CI, a signed physical
device pass, and TestFlight processing. Simulator-only evidence is not treated as
release proof.
