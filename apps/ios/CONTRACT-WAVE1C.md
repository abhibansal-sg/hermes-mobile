# Wave 1C Contract — Extensions & Push (dormant)

Ground rules per CONTRACT-WAVE1.md. The parent owns project.yml, entitlements
files, and target definitions — modules write Swift sources into pre-created
directories and DOCUMENT required plist/entitlement keys in integrationNotes
instead of editing config.

Shared plumbing (provided by parent before modules run):
- App group: `group.ai.hermes.app` (entitlements on app + both extensions)
- URL scheme: `hermesapp://` registered on the app target
  (`hermesapp://new-session`, `hermesapp://session/<storedId>`,
  `hermesapp://capture?text=...`)
- `HermesMobile/Support/SharedStore.swift` (parent-written): tiny helper over
  `UserDefaults(suiteName: "group.ai.hermes.app")` + app-group container URLs.

## X1 widgets+activity — owns `HermesWidgets/` (extension target dir)
- `HermesWidgetsBundle.swift`: @main WidgetBundle { StatusWidget();
  UsageWidget(); HermesTurnLiveActivity() }.
- `StatusWidget.swift`: small+medium; reads `WidgetSnapshot` JSON from the app
  group (written by the app — see X3): gateway connected?, active sessions,
  pending approvals count; widgetURL deep links into the app. Timeline:
  .after(15 min) refresh.
- `UsageWidget.swift`: small; today's tokens + cost from the same snapshot.
- `LiveActivity.swift`: ActivityKit. `struct HermesTurnAttributes:
  ActivityAttributes { struct ContentState: Codable, Hashable { var phase:
  String; var toolName: String?; var elapsedSeconds: Int; var needsApproval:
  Bool }; var sessionTitle: String }`. Lock screen + Dynamic Island (compact:
  hermes glyph + elapsed; expanded: title, phase/tool, approval badge).
  Pure UI — starting/updating happens app-side (X3).

## X2 share-ext — owns `HermesShare/` (extension target dir)
- `ShareViewController.swift`: SLComposeServiceController-free modern approach:
  a small SwiftUI-hosted sheet (UIHostingController) showing the shared
  items (text/URL/image count) + optional comment field + "Queue for Hermes"
  button. On confirm: persist `SharedInboxItem` JSON (+ image data files) into
  the app group via SharedStore conventions, then completeRequest. NO network
  from the extension.
- Document NSExtensionActivationRule needs (text, URL, images up to 4) for
  the parent's Info.plist.

## X3 app-side glue — owns `HermesMobile/Support/WidgetSnapshotWriter.swift`,
`HermesMobile/Support/LiveActivityManager.swift`,
`HermesMobile/Support/SharedInboxDrainer.swift`, `HermesMobile/Support/PushRegistrar.swift`
- WidgetSnapshotWriter: assemble WidgetSnapshot {connected, activeSessions,
  pendingApprovals, tokensToday, costToday, updatedAt} — inputs passed in;
  write JSON to app group + WidgetCenter.shared.reloadAllTimelines(). Hook
  points (document): ConnectionStore phase changes, InboxStore count changes,
  UsageView fetch (or a lightweight /api/analytics/usage fetch on foreground).
- LiveActivityManager: start/update/end HermesTurnAttributes activity from
  ChatStore turn lifecycle (hooks documented: message.start → start;
  tool.start → update toolName; approval.request → needsApproval; complete →
  end after 2s). Guard Activity availability + activityEnablement; no-throw.
- SharedInboxDrainer: on app foreground, read app-group shared inbox items →
  for each: open a NEW session and send "Shared from iPhone: <comment>\n<text/url>"
  (+ attach images via AttachmentStore pipeline); then clear. Keep serial,
  newest last; surface count via a toast hook (document).
- PushRegistrar: behind `UserDefaults "hermes.pushEnabled"`:
  UIApplication.registerForRemoteNotifications; delegate hook for token →
  POST {base}/api/push/register {token, platform: "ios"} (endpoint will exist
  server-side; treat 404 as soft-fail). Document the AppDelegate adaptor
  needed (UIApplicationDelegateAdaptor) for token callbacks.

## X4 server-push (dormant) — owns gateway-side files ONLY:
`/Users/abbhinnav/.hermes/hermes-agent/hermes_cli/push_notify.py` (new) +
documented small hooks (do NOT apply hooks; the parent integrates them):
- push_notify.py: APNs HTTP/2 sender using a .p8 token key (path from env
  HERMES_APNS_KEY_FILE, key id HERMES_APNS_KEY_ID, team id HERMES_APNS_TEAM_ID,
  topic HERMES_APNS_TOPIC default "ai.hermes.app"), JWT ES256 via PyJWT +
  cryptography (check venv availability: /Users/abbhinnav/.hermes/hermes-agent/venv/bin/python -c "import jwt, cryptography").
  Device token registry: JSON file ~/.hermes/push_tokens.json (registered via
  a new REST endpoint — provide the FastAPI route code in your file as a
  ready-to-mount APIRouter: POST /api/push/register, DELETE /api/push/register).
  `def notify(event_type: str, title: str, body: str, payload: dict)` — sends
  alert pushes to all registered tokens, drops invalid tokens on 410.
  All behind env HERMES_PUSH_ENABLED truthy + key file existing; silent no-op
  otherwise. Unit-testable pure-function JWT/header builders.
- Document (don't apply) the two gateway hook lines: tui_gateway approval
  emission + message.complete for long turns, and cron failure notification.

Return JSON: files, publicAPI, integrationNotes, risks.
