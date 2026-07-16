# Hermes Mobile — Release Notes

## Build 113 — Mobile Foundation — 2026-07-16

### What’s new

- Offline-first sessions and transcripts with scope-safe caches, atomic manifest updates, cached content during sync, and offline search.
- A durable work pipeline for prompts, App Intents, Share-sheet jobs, drafts, and attachments that resumes safely after relaunch.
- Background manifest refresh, silent sync handling, and suspension-time state flushing.
- A durable approval inbox plus notification actions that work from cold launch, with APNs authority and duplicate suppression.
- App Lock safeguards, immediate app-switcher privacy shielding, and separate **Go Offline** and **Forget Gateway** controls.

### Improved

- Revision-safe widgets and semantic Live Activity updates.
- Richer chat rendering for Mermaid, SVG, inline images, URL embeds, alerts, and file diffs.
- More truthful iPad connection state, offline composer behavior, prompt-history recall, and provider-setting guards.

### Worth testing

- Queue a prompt, App Intent, or Share-sheet item; kill and relaunch the app; confirm it resumes once without duplication.
- Lock the phone during a running turn; verify completion/approval notifications arrive once and their actions open the correct session.
- Go offline, browse cached sessions/search, then reconnect and confirm content refreshes without disappearing.
- Use App Lock and the app switcher; confirm protected content is never exposed in snapshots.
