---
name: paperclip-decommissioned
description: Paperclip is no longer in use — service stopped and removed from PM2 on 2026-06-07
metadata: 
  node_type: memory
  type: project
  originSessionId: fd1f20a2-92d7-4286-9b5a-0a71342858a3
---

On 2026-06-07 the user confirmed they are not using Paperclip anymore. The `paperclip` PM2 service was stopped and deleted (pm2 save'd, so it won't resurrect on reboot). Its hourly DB backups (~30 GB) were deleted except the newest (`~/.paperclip/instances/default/data/backups/paperclip-20260607-164559.sql.gz`). The instance data/db at `~/.paperclip` (~2 GB) remains on disk and can be restarted if needed.

This supersedes the active-use assumptions in [[project_git_factory_pipeline]], [[project_paperclip_execution_policy]], and [[project_git_factory_labels]] — treat those as historical context, not current state. Also removed the same day: Ollama and LM Studio (apps + models, ~56 GB); local inference is llama.cpp TurboQuant only ([[project_llamacpp_turboquant_setup]]).
