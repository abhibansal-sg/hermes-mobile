# Bootstrap — Hermes Mobile (paste into a fresh Claude Code session on this repo)

The repo `CLAUDE.md` auto-loads the hard rules and points at `.agent-memory/`, so
this is mostly belt-and-suspenders. Best path to continue: from this repo dir run
`claude --resume` and pick the most recent session (full context). Otherwise start
fresh and paste the block below.

---

You're picking up the **Hermes Mobile** project mid-flight. FIRST read
`.agent-memory/project_hermes_mobile.md` (top "PUBLIC LAUNCH SHIPPED" block) and
the `CLAUDE.md` hard rules. Current state (2026-06-17):

**SHIPPED:** Public open-source repo is LIVE — github.com/ab0991-oss/hermes-ios
(MIT, clean history, PRIVACY.md). Build 50 VALID on TestFlight; **external beta is
LIVE + joinable: https://testflight.apple.com/join/TeMvfFaS**. README + launch posts
(`dist/hermes-mobile/LAUNCH-POSTS.md`) are finalized with the link.

**IN THE MAINTAINERS' COURT (don't block on these):** 3 upstream PRs to
NousResearch/hermes-agent — #47530 (session.delete evict), #47535 (role-scoped
search), #47538 (scope /fast+/reasoning) — + issue #47541 (observability-hooks
appetite; gates the hook + 2 S5-auth PRs). Plan: `dist/hermes-mobile/UPSTREAM-PR-PLAN.md`.
Fork = ab0991-oss/hermes-agent; PR-author email
`268141382+ab0991-oss@users.noreply.github.com` (the `+`-form auto-passes the
contributor-check AUTHOR_MAP gate). Linear tracker **ABH-162**.

**LIKELY NEXT ASKS:** (a) user posts the launch (X needs the founder handle filled);
(b) a maintainer responds → if the issue gets a yes, open the observability-hooks PR
+ the two auth PRs per the plan; if a PR gets review/CI, fix in its worktree;
(c) optional: close shipped Linear tickets (ABH-153/154/86) — held pending user.

**ENV NOTES:** git is clean + pushed everywhere. PR worktrees `/tmp/hermes-pr-{main,
s4,search}` (worktrees of this repo; `fork` remote) + `/tmp/hermes-ios-export` (the
public repo's local clone) are EPHEMERAL (/tmp; gone on reboot — recreate per the
memory block: `git worktree add --detach /tmp/hermes-pr-X upstream/main`, `uv sync
--extra dev`, `git remote add fork https://github.com/ab0991-oss/hermes-agent.git`).
Build iOS ONLY via `scripts/ios-build.sh`. Never push `upstream` (dead URL). Never
restart the live :9119 deploy without the user's go. Trunk merge
(phase2-upstream-rebase → feat/group-collapse-pin) is intentionally HELD.
