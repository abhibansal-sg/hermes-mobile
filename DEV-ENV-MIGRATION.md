# Dev environment migration — 2026-06-23 (READ FIRST in this worktree)

> **UPDATE 2026-06-23 (later same day):** the dev environment MOVED AGAIN. The lead worktree
> + the `:9200` dev gateway now live at
> **`/Users/abbhinnav/conductor/workspaces/developer/indianapolis`** — its own in-tree
> `.hermes-dev`, the launchd `ai.hermes.dev-gateway` job was repointed here, and the dev token
> was transferred (the paired iPhone still works). The `…/workspaces/hermes-agent/developer`
> path named below is the PRIOR location; its `.hermes-dev` is now orphaned (kept as backup).
> Everything else below still describes the architecture correctly.

This worktree (`…/workspaces/hermes-agent/developer`) is the NEW, isolated developer
environment. It replaces the old `…/valencia` worktree, which was tethered into the
live daily-driver gateway's git store. Open a fresh Conductor/terminal session HERE.

## New architecture (what changed)

**Before:** `valencia` was a git worktree whose `.git` lived *inside*
`~/.hermes/hermes-agent/.git` (the live daily-driver checkout). Dev and the daily
driver shared one git repo → not isolated.

**After (now):**
- **Independent Conductor base repo:** `~/conductor/repos/hermes-agent` — its OWN
  object store, cloned `--no-local` from the mirror, **zero tie to `~/.hermes`**.
  Parked on a detached HEAD (Conductor model: base = object store, work in worktrees).
- **This worktree:** `~/conductor/workspaces/hermes-agent/developer`, branch
  `phase2-upstream-rebase`, a worktree of the independent base. Remotes: `origin`
  = private mirror (ab0991-oss/hermes-mobile), `fork` = ab0991-oss/hermes-agent,
  `upstream` = NousResearch (fetch-only, dead push URL).
- **Dev gateway:** `:9200`, `HERMES_HOME` = **in-tree** `./.hermes-dev` (gitignored).
  Everything dev — code + gateway data + sessions + token — under THIS one root.
  Managed by `scripts/dev-gateway.sh {install|start|stop|restart|status|token|pair|logs}`.
  launchd `ai.hermes.dev-gateway` (auto-start), wrapper at `./.hermes-dev/bin/dev-gateway-service`.
- **Daily driver UNTOUCHED:** `~/.hermes/hermes-agent` on `:9119` still runs the
  modified `feat/group-collapse-pin` branch. Dev can no longer affect it.

## Cleanup still to do (you run these in a plain terminal, NOT from inside valencia)

The old `valencia` worktree is clean (HEAD 5aa6b800f, 0 uncommitted, 0 unpushed — no
unique commits; the newer 02e92d3dc is on origin + here). To retire it + the old
data home:

```bash
# 1. Remove the old worktree's git registration (it belongs to the ~/.hermes base):
git -C ~/.hermes/hermes-agent worktree remove --force \
  ~/conductor/workspaces/hermes-agent/valencia

# 2. Remove the Conductor symlink that pointed at it:
rm -f ~/conductor/workspaces/hermes-agent/phase2-upstream-rebase

# 3. Old superseded dev data home (migrated in-tree already):
rm -rf ~/Developer/.hermes-dev

# (Optional) point Conductor at the new base for this project via its UI/settings
# so the "hermes-agent" project lists the `developer` workspace.
```

## Phase 2 — transition the daily driver to STOCK (DEFERRED — your call on "stock")

Not done yet (you'll define what "stock" means). When ready:
- BACK UP `~/.hermes` real session data first (it's your live gateway).
- Decide target: true upstream NousResearch stock (no plugin/seams) vs latest-but-frozen.
- Switch `~/.hermes/hermes-agent` off `feat/group-collapse-pin` → the chosen stock,
  restart the `ai.hermes.dashboard` launchd service, verify `:9119` healthy.
- This is now SAFE because dev no longer lives inside `~/.hermes`.

## Canonical facts also in `.agent-memory/project_hermes_mobile.md` → CANONICAL LOCATIONS.
