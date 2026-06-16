# HermesMobile — install on your Hermes gateway

Turn a working **hermes-agent** install into one that serves the HermesMobile
iOS app — multi-client live streaming, APNs push + Live Activities, device
pairing, sandboxed file browse, and attachment upload — **without editing any
stock file by hand.**

The mobile product is a self-contained plugin (`plugins/hermes-mobile/`) plus a
small, fully **additive** patch to 8 stock gateway files (~785 lines). The patch
only *adds* extension points ("seams"); with the plugin absent the gateway
behaves exactly like stock. Everything mobile-specific lives in the plugin.

## Prerequisites

- A **working hermes-agent** you can run (the dashboard/web UI starts — i.e. you
  installed it normally, which builds the web assets). The installer patches your
  existing **git checkout** of hermes-agent.
- `git` + `python3` available (the installer uses the same interpreter as your
  `hermes` CLI).

## Install (clone, then run)

Clone this repo and point the installer at your hermes-agent checkout:

```bash
git clone https://github.com/ab0991-oss/hermes-ios.git
hermes-ios/dist/hermes-mobile/install.sh  /path/to/your/hermes-agent
```

Add `--dry-run` to preview every step without changing anything.

> Prefer to let your agent do it? Paste the "magic prompt" from the project
> README into your Hermes agent and it runs this for you.

## What it does

1. **Applies `seams.patch`** — additive changes to `tui_gateway/server.py`,
   `tui_gateway/ws.py`, `hermes_cli/web_server.py`,
   `hermes_cli/dashboard_auth/{middleware,routes,token_auth,ws_tickets}.py`,
   `tools/approval.py` (`token_auth.py` is a new file).
2. **Drops the plugin** into your **user** plugins dir
   `~/.hermes/plugins/hermes-mobile/` (honors `$HERMES_HOME`). User-source — not
   the checkout's `.hermes/plugins/` — because the dashboard only auto-mounts a
   plugin's REST API from the trusted user dir.
3. **Installs the plugin's runtime deps** (`python-multipart`, `qrcode`) into the
   gateway's interpreter.
4. **Enables the plugin** and **seeds a stable dashboard token** at
   `~/.hermes/dashboard.token` (used for pairing).

Then export these and (re)start your gateway:

```bash
export HERMES_GATEWAY_BROADCAST=1                             # multi-client live fan-out
export HERMES_DASHBOARD_SESSION_TOKEN="$(cat ~/.hermes/dashboard.token)"   # so the app can pair
```

Verify, then pair:

```bash
hermes plugins list     # hermes-mobile -> enabled
hermes mobile-pair      # prints a hermesapp://pair link (+ QR) for the iOS app
```

(`HERMES_ENABLE_PROJECT_PLUGINS` is **not** needed — user-source plugins load by
default.)

## The seams (each is an upstream-PR candidate)

| Seam | What it adds | Stock-safe? |
|---|---|---|
| **S1** | gateway event fan-out + transport lifecycle observers | additive, empty registry no-ops |
| **S2** | post-emit observers + 3 synthetic boundary events | additive |
| **S3** | `_runtime_sid` on session rows | additive field |
| **S4** | session-scoped `fast`/`reasoning` overrides (no global-config write when a session is in scope) | additive branch |
| **S5** | pluggable dashboard **device-token auth** + approval/socket observers | accept-only; never weakens stock auth |
| **S6** | `session.delete` evicts a live session instead of refusing | behavior fix |

The patch is **additive**: with the plugin absent, the gateway behaves exactly
like stock.

## Rollback

```bash
# in your hermes-agent checkout:
git apply -R dist/hermes-mobile/seams.patch        # or wherever you ran it from
rm -rf ~/.hermes/plugins/hermes-mobile
hermes plugins disable hermes-mobile
```

## If your gateway has drifted

`seams.patch` targets a recent upstream baseline. If your checkout is far from it,
the installer falls back to a 3-way merge; if that fails, regenerate the patch
against your own base (`git diff <your-base> > seams.patch`) — the seams are small
and documented in the table above, so they re-place cleanly.
