"""Entry point: ``python -m hermes_relay`` — run the relay service.

The relay dials a stock gateway UPSTREAM and serves the phone DOWNSTREAM. Every
knob is settable three ways, in descending precedence:

    CLI flag  >  environment variable  >  built-in default

CLI flags::

    --gateway-url ws://HOST:PORT[/path]   upstream gateway (parsed to host/port)
    --gateway-host HOST                   (alt to --gateway-url)
    --gateway-port PORT
    --token TOKEN                         gateway ?token= auth
    --token-file PATH                     read the token from a file (keeps it
                                          out of argv / the process table)
    --listen HOST:PORT                    phone-facing downstream bind
    --health-path PATH                    HTTP health path on the downstream port
    --no-health                           disable the health surface
    --log-level LEVEL

Environment variables (back-compat with ``scripts/run-relay.sh`` /
``launch_relay.sh``):

    HERMES_RELAY_GATEWAY_TOKEN     (required unless --token/--token-file given)
    HERMES_RELAY_GATEWAY_URL       ws://host:port (overrides host/port)
    HERMES_RELAY_GATEWAY_HOST      default 127.0.0.1
    HERMES_RELAY_GATEWAY_PORT      default 9126 (isolated range; NEVER 9119 live)
    HERMES_RELAY_DOWNSTREAM_HOST   default 127.0.0.1
    HERMES_RELAY_DOWNSTREAM_PORT   default 8765
    HERMES_RELAY_HEALTH_PATH       default /healthz

SAFETY: the live production gateway on port 9119 is refused outright — the relay
is a client of an isolated/stock gateway only.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
from dataclasses import dataclass
from typing import Optional
from urllib.parse import urlsplit

from .app import RelayApp, build_default_config

#: The live production gateway port the relay must never dial.
LIVE_GATEWAY_PORT = 9119

_DEF_GATEWAY_HOST = "127.0.0.1"
_DEF_GATEWAY_PORT = 9126
_DEF_DOWNSTREAM_HOST = "127.0.0.1"
_DEF_DOWNSTREAM_PORT = 8765
_DEF_HEALTH_PATH = "/healthz"


@dataclass
class ResolvedConfig:
    """The fully-resolved connection settings (CLI > env > default)."""

    gateway_host: str
    gateway_port: int
    token: str
    downstream_host: str
    downstream_port: int
    health_path: Optional[str]
    log_level: str


def _split_hostport(value: str, *, what: str) -> tuple[Optional[str], Optional[int]]:
    """Parse ``host:port`` / ``:port`` / ``host`` into (host, port)."""
    value = value.strip()
    if not value:
        return None, None
    if value.count(":") == 1:
        host, _, port = value.partition(":")
        try:
            return (host or None), (int(port) if port else None)
        except ValueError:
            raise SystemExit(f"hermes_relay: invalid {what} {value!r} (want host:port)")
    # bare host or bare numeric port
    if value.isdigit():
        return None, int(value)
    return value, None


def _parse_ws_url(url: str) -> tuple[Optional[str], Optional[int]]:
    """Extract (host, port) from a ``ws://host:port/...`` URL."""
    parts = urlsplit(url if "://" in url else f"ws://{url}")
    return parts.hostname, parts.port


def _read_token(args: argparse.Namespace) -> str:
    if args.token:
        return args.token.strip()
    if args.token_file:
        try:
            return open(args.token_file, encoding="utf-8").read().strip()
        except OSError as exc:
            raise SystemExit(f"hermes_relay: cannot read --token-file: {exc}")
    env = os.environ.get("HERMES_RELAY_GATEWAY_TOKEN", "").strip()
    if env:
        return env
    raise SystemExit(
        "hermes_relay: a gateway token is required "
        "(--token / --token-file / HERMES_RELAY_GATEWAY_TOKEN)."
    )


def resolve_config(argv: Optional[list[str]] = None) -> ResolvedConfig:
    """Resolve the effective config from argv + env, applying CLI>env>default."""
    args = _build_parser().parse_args(argv)

    # -- gateway host/port: --gateway-url > --gateway-host/port > env > default --
    gw_host: Optional[str] = args.gateway_host
    gw_port: Optional[int] = args.gateway_port
    url = args.gateway_url or os.environ.get("HERMES_RELAY_GATEWAY_URL")
    if url:
        u_host, u_port = _parse_ws_url(url)
        gw_host = gw_host or u_host
        gw_port = gw_port or u_port
    gw_host = gw_host or os.environ.get("HERMES_RELAY_GATEWAY_HOST") or _DEF_GATEWAY_HOST
    if gw_port is None:
        env_port = os.environ.get("HERMES_RELAY_GATEWAY_PORT")
        gw_port = int(env_port) if env_port else _DEF_GATEWAY_PORT

    # -- downstream (phone-facing) bind --
    ds_host: Optional[str] = None
    ds_port: Optional[int] = None
    if args.listen:
        ds_host, ds_port = _split_hostport(args.listen, what="--listen")
    ds_host = ds_host or os.environ.get("HERMES_RELAY_DOWNSTREAM_HOST") or _DEF_DOWNSTREAM_HOST
    if ds_port is None:
        env_ds = os.environ.get("HERMES_RELAY_DOWNSTREAM_PORT")
        ds_port = int(env_ds) if env_ds else _DEF_DOWNSTREAM_PORT

    # -- health surface --
    if args.no_health:
        health_path: Optional[str] = None
    else:
        health_path = (
            args.health_path
            or os.environ.get("HERMES_RELAY_HEALTH_PATH")
            or _DEF_HEALTH_PATH
        )

    token = _read_token(args)

    if gw_port == LIVE_GATEWAY_PORT:
        raise SystemExit(
            f"hermes_relay: refusing to dial the LIVE gateway port {LIVE_GATEWAY_PORT}. "
            "Point --gateway-port/-url at an isolated/stock gateway."
        )

    return ResolvedConfig(
        gateway_host=gw_host,
        gateway_port=gw_port,
        token=token,
        downstream_host=ds_host,
        downstream_port=ds_port,
        health_path=health_path,
        log_level=(args.log_level or os.environ.get("HERMES_RELAY_LOG_LEVEL") or "INFO"),
    )


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="python -m hermes_relay",
        description="Run the Hermes mobile relay (gateway upstream, phone downstream).",
    )
    p.add_argument("--gateway-url", help="ws://HOST:PORT[/path] of the upstream gateway")
    p.add_argument("--gateway-host", help="upstream gateway host")
    p.add_argument("--gateway-port", type=int, help="upstream gateway port (NEVER 9119)")
    p.add_argument("--token", help="gateway ?token= auth (prefer --token-file)")
    p.add_argument("--token-file", help="path to a file containing the gateway token")
    p.add_argument("--listen", help="phone-facing downstream bind, HOST:PORT")
    p.add_argument("--health-path", help=f"HTTP health path (default {_DEF_HEALTH_PATH})")
    p.add_argument("--no-health", action="store_true", help="disable the health surface")
    p.add_argument("--log-level", help="logging level (default INFO)")
    return p


def _to_relay_config(rc: ResolvedConfig):
    return build_default_config(
        gateway_token=rc.token,
        gateway_host=rc.gateway_host,
        gateway_port=rc.gateway_port,
        downstream_host=rc.downstream_host,
        downstream_port=rc.downstream_port,
        health_path=rc.health_path,
    )


def main(argv: Optional[list[str]] = None) -> None:
    rc = resolve_config(argv)
    logging.basicConfig(
        level=getattr(logging, rc.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    log = logging.getLogger("hermes_relay")
    log.info(
        "relay up: gateway ws://%s:%s -> downstream ws://%s:%s (health=%s)",
        rc.gateway_host,
        rc.gateway_port,
        rc.downstream_host,
        rc.downstream_port,
        rc.health_path or "off",
    )
    app = RelayApp(_to_relay_config(rc))
    try:
        asyncio.run(app.run())
    except KeyboardInterrupt:  # graceful Ctrl-C
        log.info("relay interrupted; shutting down.")
        sys.exit(0)


if __name__ == "__main__":
    main()
