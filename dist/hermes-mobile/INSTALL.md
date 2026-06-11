# HermesMobile — plug-and-play install for stock Hermes

Turn any stock **hermes-agent** checkout into one that serves the HermesMobile
iOS app — multi-client live streaming, APNs push + Live Activities, device
pairing, sandboxed file browse, and attachment upload — **without editing any
stock file by hand.**

The mobile product is a self-contained plugin (`plugins/hermes-mobile/`) plus a
small, fully **additive** patch to 8 stock gateway files (~785 lines). The patch
only *adds* extension points ("seams"); with the plugin absent the gateway
behaves exactly like stock. Everything mobile-specific lives in the plugin.

## One-liner (run it, or paste it to your own Hermes agent)

From the root of your hermes-agent checkout:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ab0991-oss/hermes-mobile/HEAD/dist/hermes-mobile/install.sh)
```

or, if you have this repo checked out next to yours:

```bash
/path/to/hermes-mobile/dist/hermes-mobile/install.sh  /path/to/your/hermes-agent
```

Add `--dry-run` to preview every step without changing anything.

## What it does

1. **Applies `seams.patch`** — additive changes to:
   `tui_gateway/server.py`, `tui_gateway/ws.py`, `hermes_cli/web_server.py`,
   `hermes_cli/dashboard_auth/{middleware,routes,token_auth,ws_tickets}.py`,
   `tools/approval.py`. (`token_auth.py` is a new file.)
2. **Drops the plugin** into `<your-checkout>/.hermes/plugins/hermes-mobile/`.
3. **Enables it** via `hermes plugins enable hermes-mobile`.

Then export and restart your gateway:

```bash
export HERMES_ENABLE_PROJECT_PLUGINS=1   # discover .hermes/plugins/
export HERMES_GATEWAY_BROADCAST=1        # multi-client live fan-out
```

Verify:

```bash
hermes plugins list     # hermes-mobile -> enabled
hermes mobile-pair      # QR / hermesapp://pair deep-link for the iOS app
```

## The seams (each is an upstream-PR candidate)

| Seam | What it adds | Stock-safe? |
|---|---|---|
| **S1** | gateway event fan-out + transport lifecycle observers | additive, empty registry no-ops |
| **S2** | post-emit observers + 3 synthetic boundary events | additive |
| **S3** | `_runtime_sid` on session rows | additive field |
| **S4** | session-scoped `fast`/`reasoning` overrides (no global-config write when a session is in scope) | additive branch |
| **S5** | pluggable dashboard **device-token auth** + approval/socket observers | accept-only; never weakens stock auth |
| **S6** | `session.delete` evicts a live session instead of refusing 4023 | behavior fix |

S7 (WS owner-write queue), S8 (`exclude_source` filters) and S10 (REST
live-delete guard / embedded-chat reorder) from the original fork are **already
upstream** as of this baseline, and the cross-session model-switch fix is
upstream's `session["model_override"]` — so they are not in this patch.

## Rollback

```bash
git apply -R seams.patch
rm -rf .hermes/plugins/hermes-mobile
hermes plugins disable hermes-mobile
```

## If your gateway has drifted

`seams.patch` targets the upstream baseline this build was rebased onto. If your
checkout is far from it, the installer falls back to a 3-way merge; if that
fails, regenerate the patch against your own base — the seams are small and
documented in `SEAM-LEDGER.md`, so they re-place cleanly (this build is itself
the result of re-placing them across 600+ upstream commits).
