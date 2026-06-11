---
name: Paperclip API Key Scoping (wrapper)
description: Paperclip must launch via ~/bin/paperclipai wrapper, which strips ANTHROPIC_API_KEY and OPENAI_API_KEY so agent subprocesses cannot fall back from subscription to metered API.
type: feedback
originSessionId: 247467c5-73b8-4f37-81f3-a0f202fdaeca
---
Paperclip's agent subprocesses (Claude CLI under claude_local, Codex CLI under codex_local) inherit the user shell env. When Claude Max or OpenAI Codex subscription hits friction (concurrent-run cap, session refresh, rate limit), the CLIs silently fall back to `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` if present in env — billing to metered API instead of subscription. Evidence (2026-04-19): CTO had 5 runs with `billingType: metered_api` ($3.08) correlating exactly with 5 failed heartbeats during GIT-1035 rebase burst; later 50% of runs failed with Anthropic 429s on the fallback path.

**Critical implementation note (2026-04-20):** Paperclip is NOT launched from the user's interactive shell. It's **PM2-managed** (app name `paperclip`, id varies across restarts). PM2 spawns `/bin/bash -c '<inline env setup> paperclipai run'` from its own saved env snapshot in `~/.pm2/dump.pm2`. This means a shell-level wrapper at `~/bin/paperclipai` is NOT sufficient by itself — PM2 bypasses it.

**Two enforcement points (both required):**
1. `~/bin/paperclipai` wrapper (shell `unset` + exec real binary). `.zshrc` prepends `$HOME/bin` to PATH. Covers any manual `paperclipai run` invocation.
2. **PM2 dump.pm2** — the paperclip app's bash `-c` string is patched to prepend `unset ANTHROPIC_API_KEY; unset OPENAI_API_KEY;`. `OPENAI_API_KEY` is also removed from the app's `env` snapshot. `pm2 save` persists this across reboots.

**Why both:** GBrain (`bun gbrain serve`) and interactive `claude`/`codex` need the keys, so they stay in `.zshrc`. Paperclip is stripped at two independent enforcement points so either alone would catch the leak.

**How to apply:**
- If Abhi shows API billing on any paperclip agent again, first check: `ps eww -p $(pgrep -f 'paperclipai run' | head -1) | tr ' ' '\n' | grep -E 'ANTHROPIC_API_KEY|OPENAI_API_KEY'`. If anything prints, the PM2 config regressed — re-apply the dump.pm2 patch.
- Never edit `/opt/homebrew/bin/paperclipai` directly — it's the upstream binary. All enforcement goes through the wrapper or PM2 launch command.
- When Abhi upgrades `paperclipai` (brew/npm), re-verify `pm2 resurrect` still uses the patched bash args (upgrades can reset PM2 app config).
- Same pattern applies to any future local adapters that exec a subprocess inheriting shell env: patch both the shell PATH and any process manager (PM2, launchctl, systemd) holding the launch spec.
