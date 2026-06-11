---
name: project-translation-app
description: Native iPhone live speech-translation app (two modes) built on Qwen3.5-LiveTranslate-Flash; architecture + research decisions
metadata: 
  node_type: memory
  type: project
  originSessionId: 47888143-961f-4384-8afa-20e521525ea7
---

Greenfield native iPhone (SwiftUI) **live speech translation** app at `/Users/abbhinnav/projects/translation-app`. Started 2026-06-07. Full plan in repo `docs/ARCHITECTURE.md`.

**Two modes:** (1) single-device personal interpreter (listen→earphones / speak→loudspeaker); (2) shared multi-person room where each person picks the language they hear and everyone hears others in their chosen language. User's locked choices: voice **+** captions, **preserve original speaker's voice** (cloning), handle **simultaneous overlapping speakers**, build **both modes** sharing one core.

**Engine = Qwen3.5-LiveTranslate-Flash** (realtime). Non-obvious facts that drove the design:
- Realtime API id `qwen3.5-livetranslate-flash-realtime`, WebSocket `wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime`, **Singapore** endpoint (user is in SG), Bearer `DASHSCOPE_API_KEY` (region-scoped). 16kHz PCM in / 24kHz PCM out (PCM only). 60 langs in, 29 voice-out. ~2.8s. **Native voice cloning** (single-sentence enroll, beats ElevenLabs on similarity). Cloud-only, no on-device variant, no Swift SDK (use `URLSessionWebSocketTask`).
- **One target language per realtime session** (immutable) → Mode 2 fan-out = K parallel Qwen sessions per active speaker (fine at table scale; cascade ASR→MT→TTS only wins at conference scale).
- **Auto-detect VERIFIED WORKING (live probe 2026-06-07):** streamed Spanish PCM with no source set (only target=en) → got correct English back. Native any-to-any auto-detect confirmed; no per-speaker source declaration needed. Key is a workspace-scoped Singapore key (ap-southeast-1, ws-2i2jymz66lddrt52.*.maas.aliyuncs.com) but the generic `wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime` also accepts it. Default session: server_vad ON (silence 2000ms), 16kHz PCM in/out, voice "Tina". Streaming text delta event is `response.text.text` (not `.delta`); full text in `response.text.done`. Key lives in backend/relay/.env (gitignored, mode 600). Dev probes: backend/relay/{probe,autodetect_probe}.ts.

**Architecture:** 3 modules — `TranslationCore` (pure), `RoomTransport` protocol (`NullTransport` for Mode 1 / `LiveKitTransport` for Mode 2), SwiftUI UI. Mode 2 is purely additive. **LiveKit** chosen for the room (SFU + Agents + Swift-6 client; text streams carry participantIdentity → caption lanes; metadata → output-language). Two backends: a **WebSocket relay** (Mode 1 + key safety — never embed key in app) and **LiveKit + a server translation agent** (Mode 2 Qwen fan-out). Overlap handled listener-side via `AVAudioEnvironmentNode` HRTFHQ spatial seats + priority ducking + caption lanes (~2× comprehension in studies).

**Compliance:** live mic→Alibaba(China-jurisdiction) cloud = DeepSeek-style scrutiny; declare Audio Data in privacy label, route via SG entity, voice-clone needs per-participant consent + EU AI Act Art.50 (Aug 2026) AI-audio labeling.

**TestFlight (live as of 2026-06-07):** Bundle id `com.abhinav.livetranslate` (ASC app id 6777720594, registered via API id CMY5529Z8H), Apple team `6J4Y9NKRQ2`, Apple Distribution cert id `2L6646GF3C`, App Store profile "LiveTranslate App Store". Signed/uploaded headlessly with the ASC API key `3DHXXG4GHQ` + issuer (stored in repo `.issuer`, gitignored). **Manual** distribution signing (the key lacks cloud-signing permission) via `ExportOptions-TestFlight.plist`. One-command build+upload: `scripts/testflight.sh`. ASC API helper: `scripts/asc.ts` (register-bundle, create-profile, status, setup-internal). Build 1 VALID, compliance cleared, internal group + ab0991@gmail.com tester set up via API. **iPhone-only** (`TARGETED_DEVICE_FAMILY=1`). Known: CFBundleVersion stuck at "1" (XcodeGen default; add `CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"` to info.properties to make build-number bumps stick). Relay runs under **pm2** (`livetranslate-relay`) on the Mac Studio at `192.168.4.32:8787`; phone must share Wi-Fi (or use a tunnel) + macOS firewall may need to allow bun. Xcode has NO signed-in dev account (account holder ab0991@gmail.com); provisioning done purely via the ASC API.

**Decisions made:** SG DASHSCOPE key ✓, self-host on SG Mac Studio ✓, iOS 17 target ✓.

**Mode 1 VERIFIED WORKING on real iPhone via TestFlight (2026-06-07).** Two device-only bugs fixed first: AudioIOEngine re-attached the player node every start() → crash on 2nd start (fix: attach/connect in init once); mic tap used inputNode.inputFormat instead of outputFormat → 0 audio captured (fix: use outputFormat for tap+converter). Added mic-permission request + on-screen "mic: N chunks sent" diagnostic. Lesson: the capture path was never runtime-tested earlier (live tests fed PCM straight to the engine, bypassing AudioIOEngine) — always exercise the real mic path on device. Next: build the Swift LiveKitTransport + room UI for Mode 2 (backend ready; needs 2-device test).

Related: [[project_llamacpp_turboquant_setup]] (local-model alternative discussed), [[user_location]] (SG Mac Studio).
