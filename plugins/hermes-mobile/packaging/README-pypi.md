# hermes-mobile-plugin

HermesMobile iOS companion plugin for [Hermes Agent](https://github.com/NousResearch/hermes-agent): APNs push + Live Activities, desktop-phone multi-client broadcast, device pairing (`hermes mobile-pair`), sandboxed file browse, attachment upload.

## Install

```bash
pip install hermes-mobile-plugin
hermes mobile-pair
```

Hermes discovers the plugin automatically via the `hermes_agent.plugins` entry point — no file copying, no core patch. Upgrade with `pip install -U hermes-mobile-plugin`.
