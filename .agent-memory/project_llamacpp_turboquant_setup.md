---
name: TurboQuant llama.cpp OpenClaw Setup
description: Complete setup for local LLM inference via TurboQuant llama.cpp integrated with OpenClaw on M4 Max 36GB
type: project
---

## Architecture
```
Discord → OpenClaw gateway (:18789) → llama-proxy.py (:1235) → llama-server (:1234) → Gemma 4 26B-A4B
```

## Current Config (as of 2026-04-06)
- **Model**: Gemma 4 26B-A4B MoE (Q4_K_M, 16GB) — only 4B active params per token
- **Binary**: ~/llama-cpp-turboquant (branch: atomicbot-release, commit 5852a86)
- **KV cache**: Asymmetric — K=q8_0, V=turbo3 (better quality + faster than symmetric turbo3)
- **Context**: 65,000 tokens
- **Batch**: 4096
- **Speed**: ~55 t/s generation, ~627 t/s prompt processing

## Server launch command
```bash
~/llama-cpp-turboquant/build/bin/llama-server \
  --no-webui --jinja \
  -m "/Users/abbhinnav/Library/Application Support/atomicbot-desktop/llamacpp/models/gemma-4-26b-a4b/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf" \
  --cache-type-k q8_0 --cache-type-v turbo3 \
  --flash-attn auto -ngl -1 -c 65000 \
  --port 1234 --host 127.0.0.1 \
  --no-mmap -t 10 --parallel 1 -kvu -b 4096 \
  -a gemma-4-26b-a4b
```

## Key files
- `~/.openclaw/bin/start-llamacpp.sh` — launch script (needs updating for 26B-A4B + asymmetric KV)
- `~/.openclaw/bin/llama-proxy.py` — proxy: role rewriting, tool schema flattening, consecutive user merge, thinking guard (Gemma exempt)
- `~/.openclaw/bin/chat-templates/` — Qwen 3.5 + Nemotron 3 jinja templates

## Critical openclaw.json settings (all required)
- `models.providers.llamacpp.baseUrl`: `http://127.0.0.1:1235/v1` (proxy, not direct)
- `models.providers.llamacpp.api`: `openai-completions`
- **Model entry must have `"api": "openai-completions"`** — triggers OpenClaw's built-in consecutive user message merging
- `models[].reasoning`: `false` — prevents thinking params being sent
- `models[].compat.supportsUsageInStreaming`: `true` — enables token tracking
- `auth.profiles.llamacpp:default`: `{provider: "llamacpp", mode: "api_key"}` — REQUIRED, gateway won't route without it
- `auth.order.llamacpp`: `["llamacpp:default"]`
- `agents.defaults.llm.idleTimeoutSeconds`: `0` — CRITICAL: disables 60s idle timeout that kills requests during prompt processing

## Issues we solved
1. **Auth profile missing** → gateway silently dropped llamacpp requests
2. **`enable_thinking: false` injection** → proxy was killing Gemma responses (2 tokens then EOS). Fixed: proxy only injects for Qwen/Nemotron models
3. **60s LLM idle timeout** → gateway killed requests before first token on large prompts. Fixed: set to 0
4. **Consecutive user messages** → Gemma template breaks. Fixed: `api: "openai-completions"` on model entry triggers OpenClaw's built-in merge
5. **Wrong llama-server binary** → local build was 148 commits behind AtomicBot release, missing Gemma 4 chat/tool/thinking support. Fixed: rebuilt from 5852a86
6. **31B dense too slow** → 10 t/s on M4 Max 36GB due to memory bandwidth. Fixed: switched to 26B-A4B MoE (55 t/s)

## Performance notes
- First message in new session: ~60s (36K token cold prompt processing)
- Follow-up messages: ~3-6s per agent turn (KV cache reuse). Multiple tool-call turns add up.
- 36GB M4 Max has 546 GB/s bandwidth but swap pressure from other apps degrades 31B dense model
- 26B-A4B MoE is optimal for this hardware: large-model quality, small-model speed

## Upstream watch
- Commit `b8635075` (Gemma 4 specialized parser) is missing from fork. Not urgent but improves tool-call correctness. 8 conflicts prevent clean cherry-pick — wait for AtomicBot to merge it.
- PR #21451 (BF16 for Gemma 4) — fixes coherence at long context. Watch for merge.

## Also available
- Gemma 4 31B (Q4_K_M, 17GB) at `atomicbot-desktop/llamacpp/models/gemma-4-31b/` — slower but higher quality for non-time-sensitive tasks
