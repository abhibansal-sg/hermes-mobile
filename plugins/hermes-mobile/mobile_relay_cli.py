"""Operator CLI for the content-blind HRP/2 Mobile Agent Relay.

The command is plugin-owned so the stock gateway remains untouched.  It
persists only non-secret behavior in ``config.yaml``; Gateway credentials stay
in the profile token file and Relay private keys/capabilities stay in the
protected HRP/2 state store.
"""

from __future__ import annotations

import argparse
import asyncio
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import sqlite3
import stat
import sys
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit


DEFAULT_GATEWAY_HOST = "127.0.0.1"
DEFAULT_GATEWAY_PORT = 9119
DEFAULT_PAIR_TTL_SECONDS = 300
SERVICE_BASENAME = "hermes-mobile-relay"
READINESS_FILENAME = "readiness.json"
READINESS_MAX_AGE_MS = 15_000
READINESS_FUTURE_SKEW_MS = 2_000
_DNS_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")


class MobileRelayCLIError(RuntimeError):
    """Content-safe operator error; never include secret values."""


@dataclass(frozen=True, slots=True)
class MobileSettings:
    hermes_home: Path
    enabled: bool
    hub_url: str
    push_enabled: bool
    push_url: str | None
    preview_policy: str
    mailbox_ttl_seconds: int
    log_level: str
    gateway_host: str
    gateway_port: int
    gateway_token_file: Path
    state_directory: Path
    service_system: bool
    allow_insecure_local_services: bool
    hub_enrollment_token_file: Path | None


def register_cli(parser: argparse.ArgumentParser) -> None:
    """Register ``hermes mobile`` and its HRP/2 operator subcommands."""

    parser.description = "Install, pair, inspect, and revoke the HRP/2 Mobile Agent Relay."
    subs = parser.add_subparsers(dest="mobile_action")

    enable = subs.add_parser("enable", help="Enroll and install the profile relay service")
    enable.add_argument("--hub", help="Relay Hub HTTPS base URL")
    push_mode = enable.add_mutually_exclusive_group()
    push_mode.add_argument("--push-url", help="Push Gateway HTTPS base URL")
    push_mode.add_argument(
        "--no-push", action="store_true", help="Disable notifications"
    )
    enable.add_argument("--system", action="store_true", help="Install a system service")
    enable.add_argument("--gateway-host", help=argparse.SUPPRESS)
    enable.add_argument("--gateway-port", type=int, help=argparse.SUPPRESS)
    enable.add_argument("--token-file", help=argparse.SUPPRESS)
    enable.add_argument("--hub-enrollment-token-file", help=argparse.SUPPRESS)
    enable.add_argument(
        "--allow-insecure-local-services", action="store_true", help=argparse.SUPPRESS
    )

    relay = subs.add_parser("relay", help="Run the foreground service entry point")
    relay_subs = relay.add_subparsers(dest="mobile_relay_action")
    relay_subs.add_parser("run", help="Run HRP/2 in the foreground")

    status = subs.add_parser("status", help="Show service and content-free relay health")
    status.add_argument("--json", action="store_true", dest="as_json")

    pair = subs.add_parser("pair", help="Create one expiring per-device pairing offer")
    pair.add_argument("--ttl", type=int, default=DEFAULT_PAIR_TTL_SECONDS)
    pair.add_argument("--auto-approve", action="store_true")
    pair.add_argument("--hub", help=argparse.SUPPRESS)

    subs.add_parser("devices", help="List independently revocable v2 devices")

    revoke = subs.add_parser("revoke", help="Revoke one device, route, grants, and Push binding")
    revoke.add_argument("device_id")

    logs = subs.add_parser("logs", help="Read profile-scoped relay logs")
    logs.add_argument("--follow", action="store_true")
    logs.add_argument("--lines", type=int, default=100)

    disable = subs.add_parser("disable", help="Uninstall the service while retaining identity")
    disable.add_argument("--purge", action="store_true")
    disable.add_argument(
        "--yes",
        action="store_true",
        help="confirm irreversible remote revocation and local key erasure",
    )
    parser.set_defaults(func=mobile_command)


def mobile_command(args: argparse.Namespace) -> int:
    action = getattr(args, "mobile_action", None)
    if not action:
        print(
            "Usage: hermes mobile "
            "{enable|relay run|status|pair|devices|revoke|logs|disable}"
        )
        return 2
    try:
        if action == "enable":
            return _cmd_enable(args)
        if action == "relay":
            if getattr(args, "mobile_relay_action", None) != "run":
                print("Usage: hermes mobile relay run")
                return 2
            return _cmd_relay_run(args)
        if action == "status":
            return _cmd_status(args)
        if action == "pair":
            return _cmd_pair(args)
        if action == "devices":
            return _cmd_devices(args)
        if action == "revoke":
            return _cmd_revoke(args)
        if action == "logs":
            return _cmd_logs(args)
        if action == "disable":
            return _cmd_disable(args)
        raise MobileRelayCLIError(f"unknown mobile action: {action}")
    except (MobileRelayCLIError, OSError, ValueError) as exc:
        print(f"Hermes mobile: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:
        # External clients and service managers can include credentials or
        # response bodies in their exception strings.  Keep this top-level
        # operator surface content-safe while still returning a useful class.
        print(
            f"Hermes mobile: operation failed ({type(exc).__name__})",
            file=sys.stderr,
        )
        return 1


def compatibility_pair_command(args: argparse.Namespace) -> int:
    """Route ``hermes mobile-pair`` to v2 without a plaintext downgrade."""

    if getattr(args, "device_token", True) is False:
        print(
            "Hermes mobile: --shared-token is a legacy v1 downgrade and is not "
            "available for HRP/2.",
            file=sys.stderr,
        )
        return 2
    forwarded = argparse.Namespace(
        mobile_action="pair",
        ttl=getattr(args, "ttl", DEFAULT_PAIR_TTL_SECONDS),
        auto_approve=bool(getattr(args, "auto_approve", False)),
        hub=getattr(args, "url", None),
    )
    return mobile_command(forwarded)


def _cmd_enable(args: argparse.Namespace) -> int:
    current = _settings()
    allow_insecure_local_services = bool(
        getattr(args, "allow_insecure_local_services", False)
        or current.allow_insecure_local_services
    )
    hub = _canonical_service_origin(
        str(getattr(args, "hub", None) or current.hub_url),
        label="Relay Hub URL",
        allow_insecure_local=allow_insecure_local_services,
    )
    if not hub:
        raise MobileRelayCLIError("--hub is required on first enable")
    if (
        current.hub_url
        and hub.rstrip("/") != current.hub_url.rstrip("/")
        and _hub_authority_present(current)
    ):
        raise MobileRelayCLIError(
            "cannot change Relay Hub while the old Agent route exists; "
            "run `hermes mobile disable --purge --yes` against the old Hub first"
        )
    requested_push_url = str(getattr(args, "push_url", None) or "").strip()
    if requested_push_url:
        requested_push_url = _canonical_service_origin(
            requested_push_url,
            label="Push Gateway URL",
            allow_insecure_local=allow_insecure_local_services,
        )
    if (
        requested_push_url
        and current.push_url
        and requested_push_url.rstrip("/") != current.push_url.rstrip("/")
        and _push_authority_present(current)
    ):
        raise MobileRelayCLIError(
            "cannot change Push Gateway while old Push authority exists; "
            "complete `hermes mobile enable --no-push` cleanup first"
        )
    # Missing config already defaults to Push enabled in ``_settings``.  Once
    # an operator explicitly opts out, ordinary disable/re-enable must retain
    # that preference until an explicit ``--push-url`` changes it.
    push_enabled = current.push_enabled
    if bool(getattr(args, "no_push", False)):
        push_enabled = False
    elif requested_push_url:
        push_enabled = True
    if (
        push_enabled
        and not current.push_enabled
        and current.push_url
        and _push_authority_present(current)
    ):
        raise MobileRelayCLIError(
            "Push cleanup remains pending; complete "
            "`hermes mobile enable --no-push` before re-enabling notifications"
        )
    push_url = None
    if push_enabled:
        push_url = str(requested_push_url or current.push_url or "").strip()
        if not push_url:
            raise MobileRelayCLIError(
                "--push-url is required when notifications are enabled; "
                "use --no-push to opt out"
            )
    settings = replace(
        current,
        enabled=True,
        hub_url=hub,
        push_enabled=push_enabled,
        push_url=push_url,
        gateway_host=str(getattr(args, "gateway_host", None) or current.gateway_host),
        gateway_port=int(getattr(args, "gateway_port", None) or current.gateway_port),
        gateway_token_file=Path(
            getattr(args, "token_file", None) or current.gateway_token_file
        ).expanduser(),
        service_system=bool(getattr(args, "system", False)) or current.service_system,
        allow_insecure_local_services=allow_insecure_local_services,
        hub_enrollment_token_file=(
            Path(args.hub_enrollment_token_file).expanduser()
            if getattr(args, "hub_enrollment_token_file", None)
            else current.hub_enrollment_token_file
        ),
    )
    _validate_settings(settings, require_hub=True)
    if (
        not settings.push_enabled
        and settings.hub_enrollment_token_file is None
        and _operator_activation_required(settings)
    ):
        raise MobileRelayCLIError(
            "first self-host --no-push enable requires "
            "--hub-enrollment-token-file"
        )
    if not _gateway_available(settings.gateway_host, settings.gateway_port):
        raise MobileRelayCLIError(
            f"Gateway is unavailable at {settings.gateway_host}:{settings.gateway_port}"
        )

    settings.state_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name == "posix":
        os.chmod(settings.state_directory, 0o700)

    # This creates/loads the protected identity and proves exact-idempotent Hub
    # enrollment before a supervisor is changed.
    route_state = asyncio.run(_bootstrap_route(settings))
    if not settings.push_enabled and route_state != "active":
        raise MobileRelayCLIError(
            "self-hosted Relay route did not reach active state; service not installed"
        )
    launch_nonce = secrets.token_urlsafe(32)
    launched_after_ms = time.time_ns() // 1_000_000
    manager, spec = _service_manager_and_spec(
        settings, launch_nonce=launch_nonce
    )
    prior_manager, prior_spec = _service_manager_and_spec(
        current, launch_nonce=secrets.token_urlsafe(32)
    )
    installed_before = manager.is_service_installed(
        spec.name, system=settings.service_system
    )
    prior_installed = prior_manager.is_service_installed(
        prior_spec.name, system=current.service_system
    )
    scope_changed = settings.service_system != current.service_system
    cleanup_url = (
        current.push_url
        if (
            not settings.push_enabled
            and current.push_url
            and (settings.state_directory / "relay.sqlite3").is_file()
        )
        else None
    )
    cleanup_required = cleanup_url is not None
    staged_settings = (
        replace(settings, push_url=cleanup_url) if cleanup_required else settings
    )
    destructive_opt_out_started = False
    try:
        if prior_installed and (
            scope_changed
            or (cleanup_required and current.push_enabled)
        ):
            _stop_service_and_wait(
                prior_manager,
                prior_spec.name,
                system=current.service_system,
            )
            if scope_changed:
                prior_manager.uninstall_service(
                    prior_spec.name, system=current.service_system
                )

        _remove_readiness_file(settings)
        _write_settings(staged_settings)
        manager.install_service(spec, system=settings.service_system, start_now=True)
        if not _wait_for_service(
            manager,
            spec.name,
            system=settings.service_system,
            readiness=lambda: _relay_state_ready(
                settings,
                launch_nonce=launch_nonce,
                not_before_ms=launched_after_ms,
            ),
        ):
            raise MobileRelayCLIError("relay service did not reach ready state")

        if cleanup_required:
            # From this point remote Push destruction cannot be rolled back.
            # The verified managed service is already running with --no-push,
            # so pairing/send paths cannot create authority after the scan.
            destructive_opt_out_started = True
            cleanup_settings = replace(
                current,
                enabled=True,
                push_enabled=True,
                push_url=cleanup_url,
            )
            asyncio.run(_revoke_push_authority_for_opt_out(cleanup_settings))
            _write_settings(settings)
    except Exception as original_error:
        if destructive_opt_out_started:
            # ``staged_settings`` deliberately retains the old Push URL only
            # as a retry handle.  Delivery remains disabled because both the
            # persisted flag and the running service use --no-push.
            raise original_error
        rollback_errors: list[Exception] = []
        if not installed_before or scope_changed:
            try:
                manager.uninstall_service(spec.name, system=settings.service_system)
            except Exception as exc:
                rollback_errors.append(exc)
        try:
            _remove_readiness_file(settings)
        except Exception as exc:
            rollback_errors.append(exc)
        try:
            _write_settings(current)
        except Exception as exc:
            rollback_errors.append(exc)
        if prior_installed:
            try:
                prior_manager.install_service(
                    prior_spec,
                    system=current.service_system,
                    start_now=True,
                )
            except Exception as exc:
                rollback_errors.append(exc)
        if rollback_errors:
            rollback_error = MobileRelayCLIError(
                "relay enable failed and the prior service configuration could not "
                "be fully restored"
            )
            if len(rollback_errors) > 1:
                rollback_error.add_note(
                    f"{len(rollback_errors) - 1} additional rollback operation(s) failed"
                )
            raise rollback_error from rollback_errors[0]
        raise original_error
    print(f"HRP/2 Mobile Agent Relay enabled ({spec.name}).")
    return 0


def _cmd_relay_run(_args: argparse.Namespace) -> int:
    settings = _settings()
    _validate_settings(settings, require_hub=True)
    _ensure_relay_runtime()
    from hermes_relay.__main__ import main as relay_main

    relay_main(
        _relay_argv(settings, launch_nonce=secrets.token_urlsafe(32))
    )
    return 0


def _cmd_status(args: argparse.Namespace) -> int:
    settings = _settings()
    service_name = _service_name(settings.hermes_home)
    service_installed = False
    service_running = False
    service_error: str | None = None
    try:
        from hermes_cli.service_manager import get_service_manager

        manager = get_service_manager()
        service_installed = manager.is_service_installed(
            service_name, system=settings.service_system
        )
        service_running = manager.is_service_running(
            service_name, system=settings.service_system
        )
    except Exception as exc:
        service_error = type(exc).__name__

    relay_ready, readiness_error, readiness_age_ms = _relay_readiness_status(
        settings
    )
    tcp_available = _gateway_available(settings.gateway_host, settings.gateway_port)
    # Foreground ``hermes mobile relay run`` is a supported service mode and
    # has no supervisor record.  The fresh process-bound marker is the runtime
    # proof; managed-service state remains a separate diagnostic.
    operational = settings.enabled and relay_ready

    report: dict[str, Any] = {
        "protocol": 2,
        "enabled": settings.enabled,
        "ready": relay_ready,
        "operational": operational,
        "readiness_age_ms": readiness_age_ms,
        "readiness_error_code": readiness_error,
        "service": {
            "name": service_name,
            "installed": service_installed,
            "running": service_running,
            "ready": service_running and relay_ready,
            "error_code": service_error,
        },
        "gateway": {
            "host": settings.gateway_host,
            "port": settings.gateway_port,
            # A listening socket is useful diagnostic evidence, but is not an
            # authenticated Gateway health proof.  The runtime marker is only
            # published after authenticated Gateway and Hub checks succeed.
            "tcp_available": tcp_available,
            "authenticated_ready": relay_ready,
        },
        "hub_configured": bool(settings.hub_url),
        "push_enabled": settings.push_enabled,
        "state_present": (settings.state_directory / "relay.sqlite3").is_file(),
        "relay_instance_id": None,
        "hub_route_state": None,
        "devices": [],
        "outbox": {},
        "streams": [],
        "storage_last_error_code": None,
        "last_error_code": readiness_error or service_error,
    }
    if report["state_present"]:
        storage = _open_storage(settings, protected=False)
        try:
            identity = storage.load_identity()
            enrollment = storage.latest_agent_enrollment()
            storage_summary = storage.operational_summary()
            report["relay_instance_id"] = (
                identity.relay_instance_id if identity is not None else None
            )
            report["hub_route_state"] = enrollment.state if enrollment is not None else None
            report["devices"] = [_device_dict(device) for device in storage.devices()]
            report["storage_last_error_code"] = storage_summary.get(
                "last_error_code"
            )
            report.update(
                {
                    key: value
                    for key, value in storage_summary.items()
                    if key != "last_error_code"
                }
            )
        finally:
            storage.close()
    report["last_error_code"] = (
        readiness_error
        or service_error
        or report["storage_last_error_code"]
    )
    if getattr(args, "as_json", False):
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    else:
        print(
            f"HRP/2: {'enabled' if settings.enabled else 'disabled'}; "
            f"service={'running' if service_running else 'stopped'}; "
            f"relay={'ready' if relay_ready else 'not ready'}"
        )
        print(
            "Gateway TCP diagnostic: "
            f"{'reachable' if tcp_available else 'unreachable'}"
        )
        print(
            f"Devices: {len(report['devices'])}; Hub route: "
            f"{report['hub_route_state'] or 'not enrolled'}"
        )
        if service_error:
            print(f"Service manager: {service_error}")
        if readiness_error:
            print(f"Readiness: {readiness_error}")
    return 0 if operational else 1


def _cmd_devices(_args: argparse.Namespace) -> int:
    settings = _settings()
    if not (settings.state_directory / "relay.sqlite3").is_file():
        print("No HRP/2 devices are enrolled.")
        return 0
    storage = _open_storage(settings, protected=False)
    try:
        devices = storage.devices()
    finally:
        storage.close()
    if not devices:
        print("No HRP/2 devices are enrolled.")
        return 0
    print("DEVICE ID\tSTATUS\tNAME\tKEY GENERATION")
    for device in devices:
        print(
            f"{device.device_id}\t{device.status}\t{device.name}\t{device.kem_generation}"
        )
    return 0


def _cmd_pair(args: argparse.Namespace) -> int:
    settings = _settings()
    if getattr(args, "hub", None):
        settings = replace(
            settings,
            hub_url=_canonical_service_origin(
                str(args.hub),
                label="Relay Hub URL",
                allow_insecure_local=settings.allow_insecure_local_services,
            ),
        )
    _validate_settings(settings, require_hub=True)
    return asyncio.run(
        _pair_interactive(
            settings,
            ttl_seconds=int(args.ttl),
            auto_approve=bool(args.auto_approve),
        )
    )


def _cmd_revoke(args: argparse.Namespace) -> int:
    settings = _settings()
    _validate_settings(settings, require_hub=True)

    async def revoke() -> None:
        app = await _create_app(settings)
        try:
            result = await app.revoker.revoke(str(args.device_id))
            print(
                f"Revoked {result['device_id']} "
                f"({'already revoked' if result['already_revoked'] else 'confirmed'})."
            )
        finally:
            await app.close()

    asyncio.run(revoke())
    return 0


def _cmd_logs(args: argparse.Namespace) -> int:
    if int(args.lines) < 1 or int(args.lines) > 10_000:
        raise MobileRelayCLIError("--lines must be between 1 and 10000")
    settings = _settings()
    paths = _log_paths(settings.hermes_home)
    _print_log_tail(paths, int(args.lines))
    if not args.follow:
        return 0
    offsets = {path: path.stat().st_size if path.exists() else 0 for path in paths}
    try:
        while True:
            for path in paths:
                if not path.exists():
                    continue
                size = path.stat().st_size
                if size < offsets[path]:
                    offsets[path] = 0
                if size > offsets[path]:
                    with path.open("r", encoding="utf-8", errors="replace") as handle:
                        handle.seek(offsets[path])
                        for line in handle:
                            print(f"[{path.name}] {line}", end="")
                        offsets[path] = handle.tell()
            time.sleep(0.5)
    except KeyboardInterrupt:
        return 0


def _cmd_disable(args: argparse.Namespace) -> int:
    settings = _settings()
    if args.purge and not args.yes:
        response = input(
            "This revokes every mobile device and permanently erases Relay keys. "
            "Type PURGE to continue: "
        )
        if response.strip() != "PURGE":
            print("Purge cancelled; no service or state was changed.")
            return 1

    service_name = _service_name(settings.hermes_home)
    manager = None
    service_installed = False
    service_was_running = False
    try:
        from hermes_cli.service_manager import get_service_manager

        manager = get_service_manager()
    except RuntimeError:
        # No supported supervisor exists.  Lifecycle still remains safe
        # because the process lock below detects any foreground runtime.
        manager = None

    if manager is not None:
        service_installed = manager.is_service_installed(
            service_name, system=settings.service_system
        )
        if service_installed:
            service_was_running = manager.is_service_running(
                service_name, system=settings.service_system
            )
            if service_was_running:
                # The managed runtime itself holds the state lock, so it must
                # stop before the CLI can atomically take ownership.
                _stop_service_and_wait(
                    manager,
                    service_name,
                    system=settings.service_system,
                )
    RelayRuntimeAlreadyRunning, RelayRuntimeLock = _runtime_lock_classes()

    try:
        # Hold the same lock as the foreground/managed runtime across the
        # configuration transition and, for purge, every remote and local
        # destructive action.  This prevents a check-then-start race.
        with RelayRuntimeLock(settings.state_directory):
            if manager is not None and service_installed:
                manager.uninstall_service(
                    service_name, system=settings.service_system
                )
            _remove_readiness_file(settings)
            disabled = replace(settings, enabled=False)
            _write_settings(disabled)
            if not args.purge:
                print("HRP/2 relay disabled; identity and device state were retained.")
                return 0
            if not (settings.state_directory / "relay.sqlite3").is_file():
                print("HRP/2 relay disabled; no local state required purging.")
                return 0
            _validate_settings(settings, require_hub=True)
            asyncio.run(_purge_remote_and_local(settings))
            _remove_state_directory(settings)
            print(
                "HRP/2 relay disabled; remote authority revoked and local keys purged."
            )
            return 0
    except RelayRuntimeAlreadyRunning as exc:
        if manager is not None and service_was_running:
            try:
                manager.start_service(
                    service_name, system=settings.service_system
                )
            except Exception as rollback_exc:
                raise MobileRelayCLIError(
                    "another Relay process won the state lock and the prior "
                    "managed service could not be restarted"
                ) from rollback_exc
        raise MobileRelayCLIError(
            "another HRP/2 Relay process is still running; disable was aborted"
        ) from exc


async def _bootstrap_route(settings: MobileSettings) -> str:
    app = await _create_app(settings)
    try:
        enrollment = app.storage.latest_agent_enrollment()
        if enrollment is None or enrollment.route_id != app.relay_route:
            raise MobileRelayCLIError("Relay route bootstrap did not persist authority")
        return str(enrollment.state)
    finally:
        await app.close()


async def _revoke_push_authority_for_opt_out(settings: MobileSettings) -> None:
    database = settings.state_directory / "relay.sqlite3"
    if not database.is_file():
        return
    if not settings.push_enabled or not settings.push_url:
        raise MobileRelayCLIError(
            "Push cleanup requires the previously configured Push Gateway; "
            "configuration was retained"
        )
    app = await _create_app(settings)
    try:
        if app.notifications is None:
            raise MobileRelayCLIError(
                "Push cleanup client is unavailable; configuration was retained"
            )
        try:
            await app.notifications.revoke_all_authority()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            raise MobileRelayCLIError(
                "Push authority revocation was not fully confirmed; "
                "the previous Push configuration was retained for retry"
            ) from exc
        if (
            app.storage.pending_push_binding_revocations()
            or app.storage.pending_push_exchange_revocations()
        ):
            raise MobileRelayCLIError(
                "Push authority revocation remains pending; "
                "the previous Push configuration was retained for retry"
            )
    finally:
        await app.close()


async def _pair_interactive(
    settings: MobileSettings, *, ttl_seconds: int, auto_approve: bool
) -> int:
    if ttl_seconds < 1 or ttl_seconds > 3600:
        raise MobileRelayCLIError("pairing TTL must be between 1 and 3600 seconds")
    app = await _create_app(settings)
    offer_id: str | None = None
    try:
        qr = await app.pairing.create_registered_offer(
            ttl_seconds=ttl_seconds, auto_approve=auto_approve
        )
        offer_id = qr["offer_id"]
        payload = json.dumps(qr, sort_keys=True, separators=(",", ":"))
        try:
            from .mobile_pair import _render_ansi_qr

            rendered = _render_ansi_qr(payload)
        except Exception:
            rendered = None
        if rendered:
            print(rendered)
        print(payload)
        print("Scan this one-time HRP/2 payload. Do not share a screenshot.")
        while app.storage.current_time_ms() < int(qr["expires_at_ms"]):
            claim = await app.pairing.claim_ready_offer(offer_id)
            if claim is None:
                await asyncio.sleep(1.0)
                continue
            print(
                f'Pair "{claim.pair_init.device_name}"? '
                f"Verification code: {claim.verification_code}"
            )
            approved = auto_approve
            if not approved:
                response = await asyncio.to_thread(input, "Approve this device? [y/N] ")
                approved = response.strip().lower() in {"y", "yes"}
            if not approved:
                await app.pairing.cancel_offer(offer_id)
                print("Pairing rejected.")
                return 1
            result = await app.pairing.accept_claim(claim)
            print(
                f"PairAccept sent for {result['device_id']}; "
                "the service will activate it after PairConfirm."
            )
            return 0
        await app.pairing.cancel_offer(offer_id)
        print("Pairing offer expired.", file=sys.stderr)
        return 1
    except (KeyboardInterrupt, asyncio.CancelledError):
        if offer_id is not None:
            await app.pairing.cancel_offer(offer_id)
        raise
    finally:
        await app.close()


async def _purge_remote_and_local(settings: MobileSettings) -> None:
    cleanup_settings = (
        replace(settings, push_enabled=True)
        if not settings.push_enabled and settings.push_url
        else settings
    )
    app = await _create_app(cleanup_settings)
    try:
        # Re-run revocation for *every* durable device, including an already
        # local-tombstoned device from a prior lost Hub/Push response.  The
        # revoker is idempotent and queues local fail-closed state first.
        for device in app.storage.devices():
            try:
                await app.revoker.revoke(device.device_id)
            except asyncio.CancelledError:
                raise
            except Exception:
                # A second reconciliation pass below independently retries all
                # durable Hub/Push tombstones.  Final durable state, not an
                # ambiguous first response, decides whether purge may proceed.
                pass
        try:
            await app.reconcile_remote_revocations()
        except asyncio.CancelledError:
            raise
        except Exception:
            # The composition root normally isolates each revocation.  Keep
            # the CLI defensive and decide from the durable queues below.
            pass

        devices = app.storage.devices()
        device_authority_pending = any(
            device.status != "revoked"
            or getattr(device, "hub_revocation_state", None) != "confirmed"
            for device in devices
        )
        hub_pending = app.storage.pending_hub_device_revocations()
        push_binding_pending = app.storage.pending_push_binding_revocations()
        push_exchange_pending = app.storage.pending_push_exchange_revocations()
        active_push = any(
            app.storage.push_binding(device.device_id) is not None
            for device in devices
        )
        if (
            device_authority_pending
            or hub_pending
            or push_binding_pending
            or push_exchange_pending
            or active_push
        ):
            raise MobileRelayCLIError(
                "device Hub/Push revocation was not fully confirmed; "
                "Agent authority and local keys were retained for retry"
            )

        # The Agent route is last: once it is gone it can no longer authorize
        # retries for child device routes or Push cleanup.
        try:
            result = await app.hub.delete_route(app.relay_route)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            raise MobileRelayCLIError(
                "Agent route revocation was not confirmed; local keys were retained"
            ) from exc
        if result.get("route_id") != app.relay_route:
            raise MobileRelayCLIError(
                "Agent route revocation receipt did not match; local keys were retained"
            )
        app.storage.destroy_local_authority()
    finally:
        await app.close()


def _settings() -> MobileSettings:
    from hermes_cli.config import read_raw_config
    from hermes_constants import get_hermes_home

    home = Path(get_hermes_home()).expanduser()
    raw = read_raw_config()
    mobile = raw.get("mobile") if isinstance(raw.get("mobile"), dict) else {}
    allow_insecure = bool(mobile.get("allow_insecure_local_services", False))
    hub_value = str(mobile.get("hub_url") or "").strip()
    hub = (
        _canonical_service_origin(
            hub_value,
            label="Relay Hub URL",
            allow_insecure_local=allow_insecure,
        )
        if hub_value
        else ""
    )
    push_enabled = bool(mobile.get("push_enabled", True))
    push_value = str(mobile.get("push_url") or "").strip()
    configured_push = (
        _canonical_service_origin(
            push_value,
            label="Push Gateway URL",
            allow_insecure_local=allow_insecure,
        )
        if push_value
        else ""
    )
    return MobileSettings(
        hermes_home=home,
        enabled=bool(mobile.get("enabled", False)),
        hub_url=hub,
        push_enabled=push_enabled,
        # A disabled relay may retain this URL solely as a retry handle for a
        # partially confirmed Push opt-out.  ``push_enabled`` remains the only
        # switch that exposes the client to the long-lived service.
        push_url=configured_push or None,
        preview_policy=str(mobile.get("preview_policy") or "after_first_unlock"),
        mailbox_ttl_seconds=int(mobile.get("mailbox_ttl_seconds") or 86400),
        log_level=str(mobile.get("log_level") or "info"),
        gateway_host=str(mobile.get("gateway_host") or DEFAULT_GATEWAY_HOST),
        gateway_port=int(mobile.get("gateway_port") or DEFAULT_GATEWAY_PORT),
        gateway_token_file=Path(
            mobile.get("gateway_token_file") or home / "dashboard.token"
        ).expanduser(),
        state_directory=Path(mobile.get("state_directory") or home / "mobile-relay").expanduser(),
        service_system=bool(mobile.get("service_system", False)),
        allow_insecure_local_services=allow_insecure,
        hub_enrollment_token_file=(
            Path(mobile["hub_enrollment_token_file"]).expanduser()
            if mobile.get("hub_enrollment_token_file")
            else None
        ),
    )


def _write_settings(settings: MobileSettings) -> None:
    from hermes_cli.config import is_managed, read_raw_config, save_config

    _validate_service_origins(settings, require_hub=False)
    if is_managed():
        raise MobileRelayCLIError(
            "config.yaml is package-manager managed; declare the mobile block there"
        )
    raw = read_raw_config()
    existing = raw.get("mobile") if isinstance(raw.get("mobile"), dict) else {}
    mobile = dict(existing)
    mobile.update(
        {
            "enabled": settings.enabled,
            "hub_url": settings.hub_url,
            "push_enabled": settings.push_enabled,
            "preview_policy": settings.preview_policy,
            "mailbox_ttl_seconds": settings.mailbox_ttl_seconds,
            "log_level": settings.log_level,
            "gateway_host": settings.gateway_host,
            "gateway_port": settings.gateway_port,
            "gateway_token_file": str(settings.gateway_token_file),
            "state_directory": str(settings.state_directory),
            "service_system": settings.service_system,
            "allow_insecure_local_services": settings.allow_insecure_local_services,
        }
    )
    if settings.hub_enrollment_token_file is not None:
        mobile["hub_enrollment_token_file"] = str(
            settings.hub_enrollment_token_file
        )
    else:
        mobile.pop("hub_enrollment_token_file", None)
    if settings.push_url:
        mobile["push_url"] = settings.push_url
    else:
        mobile.pop("push_url", None)
    legacy_url = _legacy_relay_url(settings.hermes_home)
    if legacy_url and "legacy_relay_url" not in mobile:
        # URL is the only old preference safe to import.  Old registration,
        # pairing, and send credentials are intentionally never copied.
        mobile["legacy_relay_url"] = legacy_url
        mobile["legacy_relay_deprecated"] = True
    raw["mobile"] = mobile
    save_config(raw, strip_defaults=False)


def _legacy_relay_url(home: Path) -> str | None:
    value = os.environ.get("HERMES_MOBILE_RELAY_URL", "").strip()
    if value:
        return value
    env_path = home / ".env"
    try:
        lines = env_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if separator and key.strip() == "HERMES_MOBILE_RELAY_URL":
            return value.strip().strip("\"'") or None
    return None


def _validate_settings(settings: MobileSettings, *, require_hub: bool) -> None:
    _validate_service_origins(settings, require_hub=require_hub)
    if require_hub and not settings.hub_url:
        raise MobileRelayCLIError("Relay Hub is not configured; run `hermes mobile enable --hub URL`")
    if settings.push_enabled and not settings.push_url:
        raise MobileRelayCLIError(
            "Push Gateway is not configured; provide --push-url during enable "
            "or use --no-push"
        )
    if not _is_loopback(settings.gateway_host):
        raise MobileRelayCLIError("the Gateway must be co-located on a loopback address")
    if settings.gateway_port < 1 or settings.gateway_port > 65535:
        raise MobileRelayCLIError("Gateway port is invalid")
    token = settings.gateway_token_file
    if not token.is_file():
        raise MobileRelayCLIError(f"Gateway token file is missing: {token}")
    if os.name == "posix":
        mode = stat.S_IMODE(token.stat().st_mode)
        if mode & 0o077:
            raise MobileRelayCLIError(
                f"Gateway token file permissions must be 0600 or stricter: {token}"
            )
    if settings.hub_enrollment_token_file is not None:
        enrollment_token = settings.hub_enrollment_token_file
        if not enrollment_token.is_file():
            raise MobileRelayCLIError(
                f"Hub enrollment token file is missing: {enrollment_token}"
            )
        if os.name == "posix" and stat.S_IMODE(enrollment_token.stat().st_mode) & 0o077:
            raise MobileRelayCLIError(
                "Hub enrollment token file permissions must be 0600 or stricter"
            )
    try:
        state = settings.state_directory.resolve(strict=False)
        home = settings.hermes_home.resolve(strict=False)
        state.relative_to(home)
    except ValueError as exc:
        raise MobileRelayCLIError("Relay state directory must remain inside HERMES_HOME") from exc


def _validate_service_origins(
    settings: MobileSettings,
    *,
    require_hub: bool,
) -> None:
    if settings.hub_url:
        canonical_hub = _canonical_service_origin(
            settings.hub_url,
            label="Relay Hub URL",
            allow_insecure_local=settings.allow_insecure_local_services,
        )
        if canonical_hub != settings.hub_url:
            raise MobileRelayCLIError("Relay Hub URL must be a canonical origin")
    elif require_hub:
        raise MobileRelayCLIError("Relay Hub is not configured")
    if settings.push_url:
        canonical_push = _canonical_service_origin(
            settings.push_url,
            label="Push Gateway URL",
            allow_insecure_local=settings.allow_insecure_local_services,
        )
        if canonical_push != settings.push_url:
            raise MobileRelayCLIError("Push Gateway URL must be a canonical origin")


def _canonical_service_origin(
    value: str,
    *,
    label: str,
    allow_insecure_local: bool,
) -> str:
    raw = value.strip()
    if not raw or any(ord(character) < 0x20 for character in raw):
        raise MobileRelayCLIError(f"{label} must be a non-empty HTTP(S) origin")
    parsed = urlsplit(raw)
    scheme = parsed.scheme.lower()
    if scheme not in {"http", "https"} or not parsed.netloc:
        raise MobileRelayCLIError(f"{label} must be an absolute HTTP(S) origin")
    if parsed.username is not None or parsed.password is not None:
        raise MobileRelayCLIError(f"{label} must not contain credentials")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise MobileRelayCLIError(
            f"{label} must not contain a path, query, or fragment"
        )
    host = parsed.hostname
    if host is None or "%" in host:
        raise MobileRelayCLIError(f"{label} host is invalid")
    try:
        port = parsed.port
    except ValueError as exc:
        raise MobileRelayCLIError(f"{label} port is invalid") from exc
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        try:
            canonical_host = host.encode("idna").decode("ascii").lower()
        except UnicodeError as exc:
            raise MobileRelayCLIError(f"{label} host is invalid") from exc
        if len(canonical_host) > 253 or any(
            not _DNS_LABEL.fullmatch(part) for part in canonical_host.split(".")
        ):
            raise MobileRelayCLIError(f"{label} host is invalid")
        loopback = canonical_host == "localhost"
        netloc_host = canonical_host
    else:
        canonical_host = address.compressed.lower()
        loopback = address.is_loopback
        netloc_host = f"[{canonical_host}]" if address.version == 6 else canonical_host
    if scheme == "http" and not (allow_insecure_local and loopback):
        raise MobileRelayCLIError(
            f"plaintext {label} requires explicit loopback-only opt-in"
        )
    if port is not None and not (
        (scheme == "https" and port == 443) or (scheme == "http" and port == 80)
    ):
        netloc_host = f"{netloc_host}:{port}"
    return urlunsplit((scheme, netloc_host, "", "", ""))


def _is_loopback(host: str) -> bool:
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _gateway_available(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def _operator_activation_required(settings: MobileSettings) -> bool:
    """Check whether self-host enrollment still needs operator authority.

    The check is deliberately read-only.  A database left behind by a failed
    provisional enrollment must not be mistaken for active authority merely
    because the file exists.
    """

    database = settings.state_directory / "relay.sqlite3"
    if not database.is_file():
        return True
    try:
        uri = f"file:{database.resolve()}?mode=ro"
        with sqlite3.connect(uri, uri=True) as connection:
            row = connection.execute(
                "SELECT state FROM agent_enrollments "
                "ORDER BY created_at_ms DESC LIMIT 1"
            ).fetchone()
    except sqlite3.Error:
        return True
    return row is None or row[0] != "active"


def _push_authority_present(settings: MobileSettings) -> bool:
    """Read only whether changing endpoints could orphan Push authority."""

    database = settings.state_directory / "relay.sqlite3"
    if not database.is_file():
        return False
    try:
        uri = f"file:{database.resolve()}?mode=ro"
        with sqlite3.connect(uri, uri=True) as connection:
            binding = connection.execute(
                """SELECT 1 FROM push_bindings
                   WHERE status IN ('active','remote_revoke_pending','remote_revoked')
                   LIMIT 1"""
            ).fetchone()
            exchange = connection.execute(
                """SELECT 1 FROM push_binding_exchanges
                   WHERE (state='pending' AND remote_revoke_state!='confirmed')
                      OR (remote_revoke_state='confirmed' AND length(bind_token)>0)
                   LIMIT 1"""
            ).fetchone()
    except sqlite3.Error:
        # An unknown/older schema cannot prove the endpoint is safe to replace.
        return True
    return binding is not None or exchange is not None


def _hub_authority_present(settings: MobileSettings) -> bool:
    """Return whether changing Hub endpoints could strand Agent authority.

    Enrollment rows do not claim to be portable between independent Hub
    deployments.  Requested/provisional rows may already exist remotely after
    an unknown HTTP outcome, and active rows own routes, grants, and mailboxes.
    An unrecognized database is therefore unsafe to migrate implicitly.
    """

    database = settings.state_directory / "relay.sqlite3"
    if not database.is_file():
        return False
    try:
        uri = f"file:{database.resolve()}?mode=ro"
        with sqlite3.connect(uri, uri=True) as connection:
            row = connection.execute(
                """SELECT 1 FROM agent_enrollments
                   WHERE state IN ('requested','provisional','active')
                   LIMIT 1"""
            ).fetchone()
    except sqlite3.Error:
        return True
    return row is not None


def _ensure_relay_runtime() -> Path:
    try:
        from tools.lazy_deps import FeatureUnavailable, ensure

        try:
            ensure("mobile.relay", prompt=False)
        except FeatureUnavailable as exc:
            raise MobileRelayCLIError(
                "HRP/2 cryptography is unavailable. Install "
                "`hermes-agent[mobile]` in restricted or offline packages."
            ) from exc
    except MobileRelayCLIError:
        raise
    except ImportError as exc:
        raise MobileRelayCLIError(
            "Hermes lazy dependency support is unavailable. Install "
            "`hermes-agent[mobile]`."
        ) from exc
    try:
        import hermes_relay

        return Path(hermes_relay.__file__).resolve().parent.parent
    except ImportError:
        relay_root = Path(__file__).resolve().parents[2] / "relay"
        if not (relay_root / "hermes_relay" / "__init__.py").is_file():
            raise MobileRelayCLIError(
                "hermes-relay is not installed and no bundled relay package was found"
            )
        sys.path.insert(0, str(relay_root))
        import hermes_relay  # noqa: F401

        return relay_root


def _runtime_lock_classes():
    """Load the stdlib-only runtime lock without installing crypto extras."""

    try:
        from hermes_relay.runtime_lock import (
            RelayRuntimeAlreadyRunning,
            RelayRuntimeLock,
        )
    except ImportError as exc:
        relay_root = Path(__file__).resolve().parents[2] / "relay"
        if not (relay_root / "hermes_relay" / "runtime_lock.py").is_file():
            raise MobileRelayCLIError(
                "hermes-relay runtime locking support is unavailable"
            ) from exc
        relay_root_text = str(relay_root)
        if relay_root_text not in sys.path:
            sys.path.insert(0, relay_root_text)
        try:
            from hermes_relay.runtime_lock import (
                RelayRuntimeAlreadyRunning,
                RelayRuntimeLock,
            )
        except ImportError as fallback_exc:
            raise MobileRelayCLIError(
                "hermes-relay runtime locking support is unavailable"
            ) from fallback_exc
    return RelayRuntimeAlreadyRunning, RelayRuntimeLock


def _open_storage(settings: MobileSettings, *, protected: bool):
    _ensure_relay_runtime()
    from hermes_relay.v2.protection import platform_credential_protector
    from hermes_relay.v2.storage import RelayStorage

    protector = platform_credential_protector() if protected else None
    return RelayStorage(settings.state_directory, credential_protector=protector)


async def _create_app(settings: MobileSettings):
    _ensure_relay_runtime()
    from hermes_relay.gateway_client import GatewayConfig
    from hermes_relay.v2.app import (
        V2RelayApp,
        V2RelayConfig,
        read_protected_token_file,
    )

    try:
        token = read_protected_token_file(
            settings.gateway_token_file,
            label="Gateway token",
        )
    except (PermissionError, ValueError) as exc:
        raise MobileRelayCLIError("Gateway token file is invalid") from exc
    return await V2RelayApp.create(
        V2RelayConfig(
            gateway=GatewayConfig(
                host=settings.gateway_host,
                port=settings.gateway_port,
                token=token,
            ),
            hub_url=settings.hub_url,
            push_url=settings.push_url if settings.push_enabled else None,
            state_directory=settings.state_directory,
            allow_insecure_local_services=settings.allow_insecure_local_services,
            hub_enrollment_token_file=settings.hub_enrollment_token_file,
        )
    )


def _relay_argv(
    settings: MobileSettings, *, launch_nonce: str | None = None
) -> list[str]:
    argv = [
        "--protocol",
        "v2",
        "--gateway-host",
        settings.gateway_host,
        "--gateway-port",
        str(settings.gateway_port),
        "--token-file",
        str(settings.gateway_token_file),
        "--hub-url",
        settings.hub_url,
        "--state-dir",
        str(settings.state_directory),
        "--log-level",
        settings.log_level,
    ]
    if settings.push_enabled and settings.push_url:
        argv.extend(("--push-url", settings.push_url))
    else:
        argv.append("--no-push")
    if settings.allow_insecure_local_services:
        argv.append("--allow-insecure-local-services")
    if settings.hub_enrollment_token_file is not None:
        argv.extend(
            ("--hub-enrollment-token-file", str(settings.hub_enrollment_token_file))
        )
    if launch_nonce is not None:
        argv.extend(
            (
                "--ready-file",
                str(_readiness_path(settings)),
                "--launch-nonce",
                launch_nonce,
            )
        )
    return argv


def _service_manager_and_spec(
    settings: MobileSettings, *, launch_nonce: str | None = None
):
    from hermes_cli.service_manager import ServiceSpec, get_service_manager

    relay_root = _ensure_relay_runtime()
    stdout_path, stderr_path = _log_paths(settings.hermes_home)
    spec = ServiceSpec(
        name=_service_name(settings.hermes_home),
        description="Hermes HRP/2 Mobile Agent Relay",
        command=tuple(
            [
                sys.executable,
                "-m",
                "hermes_relay",
                *_relay_argv(settings, launch_nonce=launch_nonce),
            ]
        ),
        working_directory=relay_root,
        environment={"HERMES_HOME": str(settings.hermes_home)},
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        restart_policy="on-failure",
    )
    return get_service_manager(), spec


def _service_name(home: Path) -> str:
    from hermes_cli.service_manager import profile_scoped_service_name

    return profile_scoped_service_name(SERVICE_BASENAME, home)


def _log_paths(home: Path) -> tuple[Path, Path]:
    logs = home / "logs"
    return logs / "mobile-relay.out.log", logs / "mobile-relay.err.log"


def _readiness_path(settings: MobileSettings) -> Path:
    return settings.state_directory / READINESS_FILENAME


def _remove_readiness_file(settings: MobileSettings) -> None:
    _readiness_path(settings).unlink(missing_ok=True)


def _relay_readiness_status(
    settings: MobileSettings,
    *,
    launch_nonce: str | None = None,
    not_before_ms: int | None = None,
) -> tuple[bool, str | None, int | None]:
    """Validate the process-bound authenticated readiness heartbeat.

    The returned error codes are fixed, content-free operator diagnostics.
    Managed startup additionally supplies its launch nonce and lower timestamp
    bound; status performs every other proof without needing supervisor argv.
    """

    database = settings.state_directory / "relay.sqlite3"
    marker_path = _readiness_path(settings)
    if not database.is_file():
        return False, "state_missing", None
    try:
        marker_info = marker_path.lstat()
    except FileNotFoundError:
        return False, "marker_missing", None
    except OSError:
        return False, "marker_invalid", None
    try:
        if not stat.S_ISREG(marker_info.st_mode):
            return False, "marker_invalid", None
        if os.name == "posix" and stat.S_IMODE(marker_info.st_mode) != 0o600:
            return False, "marker_permissions", None
        if marker_info.st_size < 2 or marker_info.st_size > 4_096:
            return False, "marker_invalid", None
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
        if not isinstance(marker, dict) or set(marker) != {
            "v",
            "pid",
            "launch_nonce",
            "written_at_ms",
            "route_id",
        }:
            return False, "marker_invalid", None
        if isinstance(marker["v"], bool) or marker["v"] != 1:
            return False, "marker_invalid", None
        marker_nonce = marker["launch_nonce"]
        if (
            not isinstance(marker_nonce, str)
            or not 8 <= len(marker_nonce) <= 512
            or (launch_nonce is not None and not secrets.compare_digest(
                marker_nonce, launch_nonce
            ))
        ):
            error = (
                "marker_nonce_mismatch"
                if isinstance(marker_nonce, str) and launch_nonce is not None
                else "marker_invalid"
            )
            return False, error, None
        written_at_ms = marker["written_at_ms"]
        pid = marker["pid"]
        route_id = marker["route_id"]
        if (
            isinstance(written_at_ms, bool)
            or not isinstance(written_at_ms, int)
            or isinstance(pid, bool)
            or not isinstance(pid, int)
            or pid < 1
            or not isinstance(route_id, str)
            or not route_id
        ):
            return False, "marker_invalid", None
        now_ms = time.time_ns() // 1_000_000
        age_ms = now_ms - written_at_ms
        if not_before_ms is not None and written_at_ms < not_before_ms:
            return False, "marker_stale", age_ms
        if written_at_ms > now_ms + READINESS_FUTURE_SKEW_MS:
            return False, "marker_stale", age_ms
        if age_ms > READINESS_MAX_AGE_MS:
            return False, "marker_stale", age_ms
        if os.name == "posix":
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return False, "process_not_running", age_ms
            except PermissionError:
                pass
        uri = f"file:{database.resolve()}?mode=ro"
        with sqlite3.connect(uri, uri=True) as connection:
            identity = connection.execute(
                "SELECT 1 FROM relay_identity WHERE singleton=1"
            ).fetchone()
            enrollment = connection.execute(
                "SELECT state,route_id FROM agent_enrollments "
                "ORDER BY created_at_ms DESC LIMIT 1"
            ).fetchone()
    except (OSError, UnicodeError, ValueError, TypeError, sqlite3.Error):
        return False, "marker_invalid", None
    if (
        identity is None
        or enrollment is None
    ):
        return False, "route_not_ready", age_ms
    if not enrollment[1] or route_id != enrollment[1]:
        return False, "route_mismatch", age_ms
    allowed_states = {"active"} if not settings.push_enabled else {"provisional", "active"}
    if enrollment[0] not in allowed_states:
        return False, "route_not_ready", age_ms
    return True, None, age_ms


def _relay_state_ready(
    settings: MobileSettings,
    *,
    launch_nonce: str,
    not_before_ms: int,
) -> bool:
    """Return whether managed startup published its exact readiness proof."""

    ready, _error, _age = _relay_readiness_status(
        settings,
        launch_nonce=launch_nonce,
        not_before_ms=not_before_ms,
    )
    return ready


def _stop_service_and_wait(
    manager: Any,
    name: str,
    *,
    system: bool,
) -> None:
    if not manager.is_service_running(name, system=system):
        return
    manager.stop_service(name, system=system)
    for _ in range(100):
        if not manager.is_service_running(name, system=system):
            return
        time.sleep(0.05)
    raise MobileRelayCLIError("existing relay service did not stop cleanly")


def _wait_for_service(
    manager: Any,
    name: str,
    *,
    system: bool,
    readiness=lambda: True,
) -> bool:
    for _ in range(600):
        if manager.is_service_running(name, system=system) and readiness():
            return True
        time.sleep(0.1)
    return False


def _device_dict(device: Any) -> dict[str, Any]:
    return {
        "device_id": device.device_id,
        "name": device.name,
        "status": device.status,
        "key_generation": device.kem_generation,
        "preview_generation": device.preview_generation,
    }


def _print_log_tail(paths: tuple[Path, Path], lines: int) -> None:
    for path in paths:
        print(f"==> {path} <==")
        if not path.exists():
            print("(not created)")
            continue
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            content = handle.readlines()
        for line in content[-lines:]:
            print(line, end="" if line.endswith("\n") else "\n")


def _remove_state_directory(settings: MobileSettings) -> None:
    state = settings.state_directory.resolve(strict=False)
    home = settings.hermes_home.resolve(strict=False)
    if state.parent != home or state.name != "mobile-relay":
        raise MobileRelayCLIError(
            "refusing to purge a nonstandard state directory; remove it manually after review"
        )
    if state.exists():
        shutil.rmtree(state)


__all__ = [
    "MobileRelayCLIError",
    "MobileSettings",
    "compatibility_pair_command",
    "mobile_command",
    "register_cli",
]
