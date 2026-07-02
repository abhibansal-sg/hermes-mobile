# Hermes Mobile — Release Notes

Build 55 — 2026-07-02

WHAT'S NEW
- Manual Compress context action (iOS) (ABH-222)
- Mobile approval-bypass (YOLO/flow-state) toggle (iOS) (ABH-227)
- Server — plugin toolset-config routes (GET/PUT /toolsets/{name}/config) (ABH-224)

FIXED
- Require approve scope on /devices/issue and DELETE /devices/{id} (ABH-275)
- Gate local notifications on per-event push toggles (ABH-269)
- Server-side unregister device token when notifications disabled (ABH-270)
- Surface cron delivery failures
- Route widget approvals to inbox
- Pass api_mode so anthropic key validation sends x-api-key (ABH-259)
- Require approve scope on GET /toolsets/{name}/config (ABH-261)
- Require approve scope on GET /devices (ABH-263)
- Surface rejected provider-key validation_detail on iOS entry sheet (ABH-234)
- Render delete icons in theme.destructive red across cron/chat/drawer (ABH-235)
- Bound session→device correlation index (no per-session leak) (ABH-252)
- Audit websocket approval responses
- Run provider-key validation off the event loop (asyncio.to_thread) (ABH-245)
- Hide unprovisionable openrouter/custom provider skeletons (ABH-233)
- Fix mobile provider key disconnect validation

IMPROVED
- Fire iOS output-context hook via plugin-owned session->device correlation (ABH-221)

WORTH TRYING
- Try: Manual Compress context action (iOS) (ABH-222)
- Try: Mobile approval-bypass (YOLO/flow-state) toggle (iOS) (ABH-227)
- Try: Server — plugin toolset-config routes (GET/PUT /toolsets/{name}/config) (ABH-224)

(+4 server-side/infra changes active on the gateway, no app UI change)

