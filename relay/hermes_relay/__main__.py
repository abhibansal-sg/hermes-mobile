"""Entry point: ``python -m hermes_relay`` — run the relay service.

The relay dials a stock gateway UPSTREAM and serves the phone DOWNSTREAM. Every
knob is settable three ways, in descending precedence:

    CLI flag  >  environment variable  >  built-in default

CLI flags::

    --gateway-url ws://HOST:PORT[/path]   upstream gateway (parsed to host/port)
    --gateway-host HOST                   (alt to --gateway-url)
    --gateway-port PORT                   v1 refuses 9119; v2 permits loopback 9119
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

SAFETY: v1 refuses port 9119 and all tests use an isolated Gateway on 9123+.
Production HRP/2 may use the real 9119 Gateway only on loopback and only with a
token file; it refuses remote Gateway hosts and process-visible token sources.
"""

from __future__ import annotations

import argparse
import asyncio
import ipaddress
import json
import logging
import os
import secrets
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import urlsplit

from .app import RelayApp, build_default_config
from .runtime_lock import (
    RelayRuntimeAlreadyRunning,
    RelayRuntimeLock,
    _RelayRuntimeLock,
)
from .secure_files import read_secure_text_file
from .v2.service_url import canonical_service_origin

#: The live production gateway port the relay must never dial.
LIVE_GATEWAY_PORT = 9119

_DEF_GATEWAY_HOST = "127.0.0.1"
_DEF_GATEWAY_PORT = 9126
_DEF_V2_GATEWAY_PORT = LIVE_GATEWAY_PORT
_DEF_DOWNSTREAM_HOST = "127.0.0.1"
_DEF_DOWNSTREAM_PORT = 8765
_DEF_HEALTH_PATH = "/healthz"
_V2_READINESS_FILENAME = "readiness.json"


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
    protocol: str = "v1"
    hub_url: str | None = None
    push_url: str | None = None
    state_directory: str | None = None
    allow_insecure_local_services: bool = False
    create_pair_offer: bool = False
    pair_ttl_seconds: int = 300
    pair_auto_approve: bool = False
    hub_enrollment_token_file: str | None = None
    ready_file: str | None = None
    launch_nonce: str | None = None


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
            return read_secure_text_file(
                Path(args.token_file), owner_only=False
            ).strip()
        except (OSError, PermissionError, ValueError) as exc:
            raise SystemExit(f"hermes_relay: cannot read --token-file: {exc}")
    env = os.environ.get("HERMES_RELAY_GATEWAY_TOKEN", "").strip()
    if env:
        return env
    raise SystemExit(
        "hermes_relay: a gateway token is required "
        "(--token / --token-file / HERMES_RELAY_GATEWAY_TOKEN)."
    )


def _read_v2_token(args: argparse.Namespace) -> str:
    """HRP/2 services load the local Gateway secret from a protected file."""

    if args.token:
        raise SystemExit(
            "hermes_relay: HRP/2 refuses --token because argv is process-visible; "
            "use --token-file."
        )
    if not args.token_file:
        raise SystemExit("hermes_relay: HRP/2 requires --token-file.")
    try:
        token = read_secure_text_file(
            Path(args.token_file), owner_only=True
        ).strip()
    except (OSError, PermissionError, ValueError) as exc:
        raise SystemExit(f"hermes_relay: cannot read --token-file: {exc}")
    if not token:
        raise SystemExit("hermes_relay: --token-file is empty.")
    return token


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
        gw_port = (
            int(env_port)
            if env_port
            else (_DEF_V2_GATEWAY_PORT if args.protocol == "v2" else _DEF_GATEWAY_PORT)
        )

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

    token = _read_v2_token(args) if args.protocol == "v2" else _read_token(args)

    if args.protocol == "v1" and gw_port == LIVE_GATEWAY_PORT:
        raise SystemExit(
            f"hermes_relay: refusing to dial the LIVE gateway port {LIVE_GATEWAY_PORT}. "
            "Point --gateway-port/-url at an isolated/stock gateway."
        )
    if args.protocol == "v2" and not _is_loopback_host(gw_host):
        raise SystemExit(
            "hermes_relay: HRP/2 requires a co-located loopback Gateway; "
            "Gateway credentials are never sent to a remote host."
        )

    if args.protocol == "v2" and not args.hub_url:
        raise SystemExit("hermes_relay: HRP/2 requires --hub-url.")
    if args.protocol == "v2" and not args.no_push and not args.push_url:
        raise SystemExit("hermes_relay: HRP/2 requires --push-url or --no-push.")
    if args.protocol == "v2":
        try:
            args.hub_url = canonical_service_origin(
                args.hub_url,
                label="Hub URL",
                allow_insecure_local=args.allow_insecure_local_services,
            )
            if args.push_url is not None:
                args.push_url = canonical_service_origin(
                    args.push_url,
                    label="Push Gateway URL",
                    allow_insecure_local=args.allow_insecure_local_services,
                )
        except ValueError as exc:
            raise SystemExit(f"hermes_relay: {exc}") from exc
    if bool(args.ready_file) != bool(args.launch_nonce):
        raise SystemExit(
            "hermes_relay: --ready-file and --launch-nonce must be supplied together."
        )
    if args.launch_nonce is not None and (
        not 32 <= len(args.launch_nonce) <= 128
        or any(
            char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
            for char in args.launch_nonce
        )
    ):
        raise SystemExit("hermes_relay: --launch-nonce is invalid.")
    if args.ready_file is not None:
        if args.protocol != "v2" or args.state_dir is None:
            raise SystemExit(
                "hermes_relay: process readiness requires HRP/2 and --state-dir."
            )
        ready_parent = Path(args.ready_file).expanduser().resolve(strict=False).parent
        state_directory = Path(args.state_dir).expanduser().resolve(strict=False)
        if (
            ready_parent != state_directory
            or Path(args.ready_file).name != _V2_READINESS_FILENAME
        ):
            raise SystemExit(
                "hermes_relay: --ready-file must name the reserved readiness file "
                "directly inside --state-dir."
            )

    return ResolvedConfig(
        gateway_host=gw_host,
        gateway_port=gw_port,
        token=token,
        downstream_host=ds_host,
        downstream_port=ds_port,
        health_path=health_path,
        log_level=(args.log_level or os.environ.get("HERMES_RELAY_LOG_LEVEL") or "INFO"),
        protocol=args.protocol,
        hub_url=args.hub_url,
        push_url=None if args.no_push else args.push_url,
        state_directory=args.state_dir,
        allow_insecure_local_services=args.allow_insecure_local_services,
        create_pair_offer=args.pair,
        pair_ttl_seconds=args.pair_ttl,
        pair_auto_approve=args.auto_approve,
        hub_enrollment_token_file=args.hub_enrollment_token_file,
        ready_file=args.ready_file,
        launch_nonce=args.launch_nonce,
    )


def _is_loopback_host(host: str) -> bool:
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="python -m hermes_relay",
        description="Run the Hermes Mobile Agent Relay (legacy v1 or encrypted HRP/2).",
    )
    p.add_argument(
        "--protocol", choices=("v1", "v2"), default="v1",
        help="relay protocol generation (default v1; v2 is explicit opt-in)",
    )
    p.add_argument("--gateway-url", help="ws://HOST:PORT[/path] of the upstream gateway")
    p.add_argument("--gateway-host", help="upstream gateway host")
    p.add_argument(
        "--gateway-port",
        type=int,
        help="upstream Gateway port (v1 refuses 9119; v2 permits loopback 9119)",
    )
    p.add_argument("--token", help="gateway ?token= auth (prefer --token-file)")
    p.add_argument("--token-file", help="path to a file containing the gateway token")
    p.add_argument("--listen", help="phone-facing downstream bind, HOST:PORT")
    p.add_argument("--health-path", help=f"HTTP health path (default {_DEF_HEALTH_PATH})")
    p.add_argument("--no-health", action="store_true", help="disable the health surface")
    p.add_argument("--log-level", help="logging level (default INFO)")
    p.add_argument("--hub-url", help="HRP/2 Relay Hub HTTPS URL")
    p.add_argument(
        "--hub-enrollment-token-file",
        help="owner-only file containing self-host Hub activation authority",
    )
    p.add_argument("--push-url", help="HRP/2 Push Gateway HTTPS URL")
    p.add_argument("--no-push", action="store_true", help="run HRP/2 without notifications")
    p.add_argument("--state-dir", help="profile-scoped HRP/2 state directory")
    p.add_argument("--ready-file", help=argparse.SUPPRESS)
    p.add_argument("--launch-nonce", help=argparse.SUPPRESS)
    p.add_argument(
        "--allow-insecure-local-services",
        action="store_true",
        help="allow HTTP only for loopback self-host development",
    )
    p.add_argument("--pair", action="store_true", help="create/register a pairing offer at startup")
    p.add_argument("--pair-ttl", type=int, default=300, help="pairing offer TTL seconds")
    p.add_argument(
        "--auto-approve",
        action="store_true",
        help="explicitly bypass human code confirmation for the startup offer",
    )
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
    try:
        if rc.protocol == "v2":
            asyncio.run(_run_v2(rc))
        else:
            log.info(
                "relay up: gateway ws://%s:%s -> downstream ws://%s:%s (health=%s)",
                rc.gateway_host,
                rc.gateway_port,
                rc.downstream_host,
                rc.downstream_port,
                rc.health_path or "off",
            )
            app = RelayApp(_to_relay_config(rc))
            asyncio.run(app.run())
    except KeyboardInterrupt:  # graceful Ctrl-C
        log.info("relay interrupted; shutting down.")
        sys.exit(0)
    except RelayRuntimeAlreadyRunning:
        log.error(
            "another HRP/2 Relay process already owns this state directory"
        )
        sys.exit(1)


async def _run_v2(rc: ResolvedConfig) -> None:
    from .v2.storage import resolve_state_directory

    state_directory = (
        Path(rc.state_directory).expanduser()
        if rc.state_directory is not None
        else resolve_state_directory()
    ).resolve(strict=False)
    with RelayRuntimeLock(state_directory):
        await _run_v2_locked(rc, state_directory=state_directory)


async def _run_v2_locked(rc: ResolvedConfig, *, state_directory: Path) -> None:
    from .gateway_client import GatewayConfig
    from .v2.app import V2RelayApp, V2RelayConfig

    assert rc.hub_url is not None
    ready_path = Path(rc.ready_file).expanduser() if rc.ready_file else None
    if ready_path is not None:
        _remove_runtime_readiness(ready_path)
    app = await V2RelayApp.create(
        V2RelayConfig(
            gateway=GatewayConfig(
                host=rc.gateway_host,
                port=rc.gateway_port,
                token=rc.token,
            ),
            hub_url=rc.hub_url,
            push_url=rc.push_url,
            state_directory=state_directory,
            allow_insecure_local_services=rc.allow_insecure_local_services,
            hub_enrollment_token_file=(
                Path(rc.hub_enrollment_token_file).expanduser()
                if rc.hub_enrollment_token_file is not None
                else None
            ),
        )
    )
    if rc.create_pair_offer:
        qr = await app.pairing.create_registered_offer(
            ttl_seconds=rc.pair_ttl_seconds,
            auto_approve=rc.pair_auto_approve,
        )
        # This one-time object is intended for QR encoding by the invoking
        # terminal.  It is never logged and never placed in a URL.
        print(json.dumps(qr, sort_keys=True, separators=(",", ":")), flush=True)
    readiness_callback = None
    if ready_path is not None:
        assert rc.launch_nonce is not None

        def readiness_callback(route_id: str | None) -> None:
            if route_id is None:
                _remove_runtime_readiness(ready_path)
                return
            _write_runtime_readiness(
                ready_path,
                launch_nonce=rc.launch_nonce,
                route_id=route_id,
            )

    try:
        await app.run(readiness_callback=readiness_callback)
    finally:
        if ready_path is not None:
            _remove_runtime_readiness(ready_path)


def _remove_runtime_readiness(path: Path) -> None:
    if path.name != _V2_READINESS_FILENAME:
        raise ValueError("refusing to remove a non-readiness runtime path")
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def _write_runtime_readiness(
    path: Path,
    *,
    launch_nonce: str,
    route_id: str,
) -> None:
    """Atomically publish one content-free, process-bound heartbeat."""

    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name == "posix":
        os.chmod(path.parent, 0o700)
    payload = json.dumps(
        {
            "v": 1,
            "pid": os.getpid(),
            "launch_nonce": launch_nonce,
            "written_at_ms": time.time_ns() // 1_000_000,
            "route_id": route_id,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    temporary = path.with_name(
        f".{path.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor: int | None = None
    try:
        descriptor = os.open(temporary, flags, 0o600)
        if os.name == "posix":
            os.fchmod(descriptor, 0o600)
        written = 0
        while written < len(payload):
            written += os.write(descriptor, payload[written:])
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.replace(temporary, path)
        if os.name == "posix":
            os.chmod(path, 0o600)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
