# UI Batch E Contract — Stock-Server Compatibility

Rules: INTERFACES.md recap; theme engine live; Batches B/C/D landed — read
POST-D state of every file. Goal: one binary that runs fully against the
user's patched gateway AND degrades gracefully against STOCK stable
hermes-agent (no fork patches). Branch-only server features: POST /api/upload,
event broadcast (stored_session_id enrichment), POST/DELETE /api/push/register,
hermes mobile-pair. Everything else the app uses is stock.

## E1 capabilities — owns Stores/ServerCapabilities.swift (new) + minimal
gates in ComposerView/SettingsView/ConnectionStore
- @MainActor @Observable final class ServerCapabilities. States per feature:
  unknown / available / unavailable. Features: upload, pushRegistry,
  broadcast.
- Probing (cheap, cached per serverURL in UserDefaults so reconnects don't
  re-probe; re-probe on configure() to a NEW url or app-version change):
  * upload: lazy-on-first-need OR eager single probe at connect — eager:
    POST /api/upload with an EMPTY body and inspect status: 400 ("multipart
    field 'file' required") = available; 404/405 = unavailable. Zero side
    effects either way.
  * pushRegistry: existing PushRegistrar 404 soft-fail becomes the signal —
    wire it to set capabilities.pushRegistry = .unavailable; a 2xx/4xx-
    validation response = available.
  * WHILE IN PushRegistrar: add APNs environment reporting. The register
    POST body gains "env": "sandbox" | "production". Detection: dev-signed
    Xcode builds embed a provisioning profile; TestFlight/App Store builds
    don't — `Bundle.main.path(forResource: "embedded", ofType:
    "mobileprovision") != nil ? "sandbox" : "production"` (simulator →
    "sandbox"). The server registry routes per token (already landed).
  * broadcast: passive — ConnectionStore router marks .available on the
    first event carrying stored_session_id; stays .unknown otherwise (never
    provably unavailable; that's fine).
- ConnectionStore owns/exposes it (var capabilities), probes after a
  successful configure/connect.
- UI gates (minimal diffs):
  * ComposerView "+" menu: photo/camera/scan items hidden when upload ==
    .unavailable (menu may collapse to nothing → hide the "+" too).
  * SettingsView Notifications section: when pushRegistry == .unavailable,
    disable the toggle with footnote "Not supported by this server."
  * No gate needed for broadcast (features are already passive).

## E2 generic capture — owns Views/Capture/QuickCaptureView.swift + the
drawer footer entry + a SettingsView row
- Rename surface: "Quick note" (square.and.pencil-style note glyph, NOT
  brain). The brain/gbrain identity must not appear for default users.
- Behavior: sends "<prefix><text>" to a NEW session; prefix from UserDefaults
  "hermes.capturePrefix" (default "Note: ").
- Visibility: drawer footer capture entry shown only when UserDefaults
  "hermes.captureEnabled" == true (DEFAULT FALSE). SettingsView gains a
  "Quick capture" section: enable toggle + prefix TextField (footnote:
  "Prefix is prepended to every quick note — e.g. route to a memory store.").
- MIGRATION for the user's device: if the old gbrain capture was used
  (no reliable marker — skip auto-migration; the parent will hand-set the
  user's prefix after install; note this in integrationNotes).

## E3 verification — integrator stage (no module owns files)
Stand up a STOCK dashboard and prove degradation:
1. Find upstream baseline: cd /Users/abbhinnav/.hermes/hermes-agent &&
   git merge-base hermes-mobile origin/main (or main). git worktree add
   /tmp/hermes-stock <merge-base>. Run its dashboard:
   HERMES_DASHBOARD_SESSION_TOKEN=stock-test <worktree>/venv? — the worktree
   shares no venv; run via the EXISTING venv but with PYTHONPATH/cwd at the
   worktree so the stock code executes:
   cd /tmp/hermes-stock && HERMES_DASHBOARD_SESSION_TOKEN=stock-test
   /Users/abbhinnav/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main
   dashboard --no-open --tui --host 127.0.0.1 --port 9125
   (HERMES_HOME stays default — it will share ~/.hermes state; acceptable:
   create/close only test sessions; do NOT bulk-delete; alternatively set
   HERMES_HOME=/tmp/hermes-stock-home for full isolation if the dashboard
   boots cleanly there — try isolated first, fall back to shared).
2. Verify stock-ness: POST /api/upload → 404; /api/push/register → 404.
3. App vs stock: launch sim app with SIMCTL_CHILD_HERMES_URL=http://127.0.0.1:9125
   + token stock-test. Screen-tour: home, drawer, settings (push row shows
   unsupported), composer ("+" hidden), send a REAL prompt → streaming works
   (the stock gateway runs the same model config). Screenshot each to
   /tmp/hermes-uiE-stock-*.png and READ them.
4. Full test suite vs the PATCHED live gateway (9119) as usual — no
   regressions (capabilities default .available... no: they PROBE; the live
   gateway passes probes, so full features verified there).
5. Tear down the worktree dashboard + worktree.
Return the standard integration JSON + stockVerified: bool + stockScreenshots.
