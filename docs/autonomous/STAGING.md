# Staging Tier — DEV → STAGING → LIVE promotion pipeline

Locked by Abhi 2026-07-02; built 2026-07-03. This is the rung that turns the
autonomous loop from "agents merge code" into "code Abhi actually lives on."

## Topology

| Tier | Port | HERMES_HOME | Code | launchd label |
|---|---|---|---|---|
| DEV | :9200 | `<dev repo>/.hermes-dev` | dev checkout, base branch | `ai.hermes.dev-gateway` |
| STAGING | :9300 | `<staging repo>/.hermes-staging` | **separate checkout** `~/Developer/products/hermes-mobile-staging`, branch `staging` | `ai.hermes.staging-gateway` |
| LIVE | :9119 dashboard | `~/.hermes` | managed install | `ai.hermes.gateway` |

- Staging is a full separate checkout + own venv + own HOME — NOT a profile
  (a profile shares the code install and gates nothing).
- `origin/staging` never gets its own commits; it is only ever fast-forwarded
  to the base branch tip by `scripts/promote-to-staging.sh` (ff-only, refuses
  divergence).
- Staging models: GLM (zai / glm-5.2) via the staging HOME's own `.env`
  (GLM key only — no Anthropic/Linear keys in staging). Real providers, per
  the locked decision.
- iOS side: TestFlight IS the app staging tier. This tier is gateway/server only.

## The pieces

- `scripts/staging-gateway.sh` (staging checkout) — install/start/stop/status/
  logs/pair; mirrors dev-gateway.sh. launchd KeepAlive keeps :9300 up.
- `scripts/promote-to-staging.sh` (staging checkout) — the DEV→STAGING rung:
  ff origin/staging to base tip → ff the checkout → `uv sync` when deps changed
  → restart gateway (kill pid; launchd respawns) → health gate. Prints
  `PROMOTED <sha>` or `FAILED: <why>`.
- SOAK beat — profile `soak` (glm-5.2), prompt
  `~/.hermes/scripts/cron-soak-prompt.txt`, wrapper `beat-soak.sh`, cron
  `loop-soak` (7:00/13:00/19:00 SGT). Each run: promote → baseline RSS/FD →
  abuse suite (WS flap ×10, 3 concurrent sessions, rapid-fire ×20, API storm
  ×50 + auth-bypass probe, malformed input, leak re-measure) → last-lines
  verdict `SOAK VERDICT: SHIP | DO-NOT-SHIP` + `SHA:` + `EVIDENCE:` lines.
  DO-NOT-SHIP files a p2 Linear issue labeled `loop:staging-blocker`.
  Inconclusive = DO-NOT-SHIP, never a pass.

## STAGING → LIVE (the human tap)

Promotion to live stays gated on Abhi — the one cheap insurance. The mechanic:
when the latest soak verdict is SHIP, Abhi (or Hermes on his explicit ask) runs
the normal live-update path for the managed install. The soak verdict for the
exact sha is the evidence to read first. NEVER automate this step.

## Invariants

1. Nothing on the staging tier ever touches :9200, :9119, `~/.hermes`, or the
   dev checkout. The soak prompt carries this as a hard fence.
2. `origin/staging` divergence = refuse + human. Same for local staging-checkout
   commits or dirty tracked files.
3. A soak run that can't interpret its own results renders DO-NOT-SHIP.
4. The soak beat promotes FIRST — a verdict is always about the current base sha,
   never a stale artifact.
