"""Entry point: ``python -m hermes_relay`` — run the relay service.

Reads connection config from the environment (never a live-gateway default):

* ``HERMES_RELAY_GATEWAY_TOKEN`` — WS ``?token=`` for the stock gateway.
* ``HERMES_RELAY_GATEWAY_PORT``  — gateway port (default 9126, the isolated
  test range; NEVER 9119, the live gateway).
* ``HERMES_RELAY_DOWNSTREAM_PORT`` — phone-facing WS port (default 8765).

The actual supervisor loop lives in :meth:`hermes_relay.app.RelayApp.run`; this
module only parses env and hands off. Kept thin so the service is one
``asyncio.run(app.run())`` away from live once the lanes are implemented.
"""

from __future__ import annotations

import asyncio
import os
import sys

from .app import RelayApp, build_default_config


def _load_config():
    token = os.environ.get("HERMES_RELAY_GATEWAY_TOKEN", "")
    if not token:
        print(
            "hermes_relay: HERMES_RELAY_GATEWAY_TOKEN is required.",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return build_default_config(
        gateway_token=token,
        gateway_port=int(os.environ.get("HERMES_RELAY_GATEWAY_PORT", "9126")),
        downstream_port=int(os.environ.get("HERMES_RELAY_DOWNSTREAM_PORT", "8765")),
    )


def main() -> None:
    app = RelayApp(_load_config())
    asyncio.run(app.run())


if __name__ == "__main__":
    main()
