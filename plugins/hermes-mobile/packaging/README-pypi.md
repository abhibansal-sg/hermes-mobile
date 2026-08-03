# hermes-mobile-plugin

Optional notification edge for the Hermes Mobile iOS client: stock lifecycle
hooks to APNs and Live Activities, plus idempotent prompt receipts. The phone
connects directly to the stock Hermes gateway; this plugin is not a chat relay.

## Install

```bash
pip install hermes-mobile-plugin
```

Hermes discovers the plugin automatically via the `hermes_agent.plugins` entry point — no file copying, no core patch. Upgrade with `pip install -U hermes-mobile-plugin`.
