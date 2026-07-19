from __future__ import annotations

import argparse
import json
from collections.abc import Sequence

import uvicorn

from .crypto import TokenVault
from .settings import Settings
from .storage import DatabaseStore


def _rewrap_token_keys() -> int:
    settings = Settings.from_env()
    if settings.auto_create_schema:
        raise RuntimeError(
            "token rewrap requires HPG_AUTO_CREATE_SCHEMA=false to avoid targeting "
            "an accidentally created empty database"
        )
    store = DatabaseStore(settings)
    if not store.ready():
        raise RuntimeError("push schema is not current; apply migrations before rewrap")
    vault = TokenVault(
        settings.token_keyring,
        current_version=settings.token_key_version,
    )
    counts = store.rewrap_token_keys(vault)
    remaining = store.token_key_versions_in_use()
    if remaining - {vault.current_version}:
        raise RuntimeError("token rewrap finished with non-current key versions")
    print(
        json.dumps(
            {
                "current_key_version": vault.current_version,
                "rewrapped": counts,
                "status": "ok",
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m push_gateway")
    parser.add_argument(
        "command",
        nargs="?",
        default="serve",
        choices=("serve", "rewrap-token-keys"),
    )
    args = parser.parse_args(argv)
    if args.command == "rewrap-token-keys":
        return _rewrap_token_keys()
    uvicorn.run("push_gateway.app:create_app", factory=True, host="0.0.0.0", port=8081)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
