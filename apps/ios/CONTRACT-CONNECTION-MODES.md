# CONTRACT — Flexible Connection Modes ("Topology B")

Status: spec approved 2026-06-18. Branch `feat/connection-modes`. Tracked: Linear (Claude Code OS project). Built via the Claude Code OS verify-loop.

## Goal

Let the iOS app connect to any of three gateway endpoints — the user's **local desktop** gateway, an explicit **remote URL**, or the **shared dashboard** — chosen explicitly in-app, so a self-hoster isn't locked into the single dashboard-on-:9119 topology.

## Architecture guardrails (non-negotiable)

- **Stock Hermes gateway stays UNTOUCHED.** All work lives in `apps/ios/` (our app) + `plugins/hermes-mobile/` (our plugin). NEVER edit stock NousResearch core (`tui_gateway/`, `hermes_cli/web_server.py` core, `ui-tui/`). The plugin is the cleanly-isolatable, upstreamable unit. Any diff touching stock core is a red flag → move it plugin-side. (Reviewers must check this.)
- **Build iOS only via `scripts/ios-build.sh`** (mutex; SIGTERM-never-kill-9; wedge recovery = logout/login).
- **Never test against the live `:9119` dashboard** — isolated gateway on `:9123+`, killed when done.
- Secrets/tokens in session/MCP env or Keychain only; never plists/source.
- Feature code on this branch → PR. `origin` (private mirror) only; `upstream` fetch-only. Do not touch the HELD trunk merge or upstream PRs #47530/#47535/#47538/#47541.

## Ground truth (what's actually true today)

- iOS already accepts arbitrary `http(s)` URLs + token (`ConnectionStore.configure`, ConnectionStore.swift:538-550).
- `WSURLBuilder` pins only the HTTP **Host header** to `127.0.0.1` (WSURLBuilder.swift:31,44) — deliberate, because the gateway validates Host against its loopback bind and Tailscale Serve fronts it. So remote-URL works today only via Serve. This Host-pinning is the real constraint, not a "forced IP."
- The desktop TUI's "embedded gateway" is a **stdio JSON-RPC subprocess that binds no socket** (`tui_gateway/entry.py`) — a phone cannot reach it. Attach mode (`HERMES_TUI_GATEWAY_URL`) already exists.
- **Canonical user setup:** Hermes Desktop app installs + OWNS the gateway. iOS support = install our plugin. Pairing must work with THAT (discovery-based), not just the maintainer's manual `:9119`.

## End-state success criteria

1. Connection screen offers an explicit mode picker: **Local desktop / Remote URL / Shared dashboard**; choice persists across relaunch.
2. Remote URL mode connects to a non-tailnet host (Host-pinning resolved).
3. Local desktop mode pairs with the gateway the host's Desktop app owns (discovery, not hardcoded); a desktop-created session appears on the phone and round-trips.
4. Survives a desktop restart with no re-pair.
5. Shared dashboard mode regression-free.
6. Unreachable endpoint → actionable error, never a silent hang.

## Increments (ordered; each independently verifiable)

- **Increment 1 — Connection-mode picker (iOS-only, FIRST loop).** `ConnectionMode` enum (`.localDesktop/.remoteURL/.sharedDashboard`) + persistence; mode-aware `ConnectionSetupView`/`WelcomeView`; routing in `HermesURLRouter`. No transport change — every mode still calls `configure(urlString:token:)`. Pure UX/persistence; ships + verifies on the sim.
- **Increment 2 — Remote-URL for non-tailnet hosts.** `WSURLBuilder` Host header derives from mode/target (loopback for Serve; real host for `0.0.0.0` binds). iOS-side; server already accepts any Host on `0.0.0.0` (no stock edit).
- **Increment 3 — Local-desktop pairing via plugin-side DISCOVERY of the Desktop-owned gateway.** Re-scoped per the plugin-boundary rule: do NOT build a new stock listener. Make `plugins/hermes-mobile/` discover/pair with whatever gateway the Hermes Desktop app owns. OPEN INVESTIGATION before build: how does the Desktop app expose its gateway (port/address/lifecycle/auth)? Prefer reusing the existing local dashboard + attach path over inventing a listener.
- **Increment 4 — Restart survival / address stability.** Recommended: Tailscale MagicDNS hostname (primary; reuses the Serve→loopback path already trusted) + fixed default port (LAN fallback). Plugin-side (`mobile_pair.py`) + iOS reconnect re-resolves address. Watch-item: MagicDNS flakiness (known fallback path).

## Verification (per increment)

Isolated gateway on `:9123` (`HERMES_GATEWAY_BROADCAST=1`, own token) → `xcodegen generate` → `scripts/ios-build.sh test ... -only-testing:<Suite/Test>` → pull screenshots/attachments from `.xcresult`. See `.claude/skills/verify-loop/SKILL.md`.

- **Inc1:** XCUITest — fresh launch shows 3 modes; select Remote URL → enter :9123 URL+token → `.connected` + session row renders; relaunch → mode persisted. Before/after screenshots.
- **Inc2:** connect sim to a `0.0.0.0`-bound :9123 via real host; `WSURLBuilder` unit tests (Host = real host non-loopback, `127.0.0.1` for Serve); regression: Serve path still pins loopback.
- **Inc3:** foreign session created on the discovered Desktop-owned gateway renders + round-trips on the phone.
- **Inc4:** kill+restart the gateway → phone reconnects, no re-pair (`reauthRequired == false`).

## Critical files

- Inc1: `ConnectionStore.swift` (ConnectionMode + persist ~538-606), `ConnectionSetupView.swift`, `WelcomeView.swift`, `App/HermesURLRouter.swift` (parsePairPayload ~107-136).
- Inc2: `WSURLBuilder.swift` (31,44), `HermesGatewayClient.swift` (103), `ConnectionStore.swift`.
- Inc3: `plugins/hermes-mobile/mobile_pair.py` (discovery) + iOS Local-mode wiring. NO stock-core edits.
- Inc4: `plugins/hermes-mobile/mobile_pair.py`, `ConnectionStore.swift` (reconnect ~384, bootstrap ~487-496).
