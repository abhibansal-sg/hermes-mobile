"""hermes-mobile — multi-client gateway plugin (iOS app + remote clients).

ABH-88 de-patch (W1): all mobile/multi-client gateway work lives here, riding
the stock plugin system plus the minimal seams catalogued in
CONTRACT-DEPATCH.md (S1 event fan-out subscribers, S2 emit observers, S3
session-info completeness).

Modules:

* ``broadcast``   — multi-client event fan-out engine (S1).
* ``push_engine`` — APNs alert + Live Activity push, gateway event intake (S2).
* ``gitbranch``   — fork-free branch lookup for the session.create fast path.
* ``mobile_pair`` — the ``hermes mobile-pair`` CLI command (QR pairing),
  registered through the stock ``register_cli_command`` facade.
* ``dashboard/api.py`` — REST routes, auto-mounted by the dashboard plugin
  system at ``/api/plugins/hermes-mobile/`` (upload, approvals, devices,
  fs browse, push registration).

``register(ctx)`` imports the gateway modules to wire the seams. That is
intentional and cheap-ish (~ms) — in the dashboard/gateway process those
modules load anyway, and in CLI-only processes the wiring is inert (the seam
lists are simply never iterated).
"""

from __future__ import annotations

import logging

_log = logging.getLogger(__name__)


def _setup_mobile_pair_parser(parser) -> None:
    """argparse wiring for ``hermes mobile-pair`` (moved from main.py)."""
    parser.description = (
        "Print a hermesapp://pair deep link and an in-terminal QR code so "
        "the HermesMobile app can scan it to configure its connection."
    )
    parser.add_argument(
        "--url",
        default=None,
        help=(
            "Override the dashboard URL embedded in the pairing code "
            "(default: auto-detect from Tailscale Serve)"
        ),
    )
    parser.add_argument(
        "--device-token",
        action="store_true",
        dest="device_token",
        default=True,
        help=(
            "Mint a revocable per-device token and embed it in the pairing "
            "code (QR v2) instead of the shared dashboard token. This is the "
            "default. Requires a server with the hermes-mobile plugin (or the "
            "legacy device routes)."
        ),
    )
    parser.add_argument(
        "--shared-token",
        action="store_false",
        dest="device_token",
        help=(
            "Use the legacy shared-dashboard-token pairing flow. Only use this "
            "for stock gateways without the device-token routes."
        ),
    )


def _cmd_mobile_pair(args) -> int:
    from . import mobile_pair

    return mobile_pair.mobile_pair_command(args)


def _wire_approval_audit() -> None:
    """Register the audit writer on the approval resolve-observer seam (S5).

    The stock pre/post_approval_request hooks fire in the WAITING request
    thread and never learn the resolver's identity (which device approved),
    so the audit record rides the resolve observer instead — it carries the
    auth context the REST/WS resolvers thread through ``audit=``.
    """
    from tools import approval as _approval

    from . import audit_log

    def _audit_resolution(session_key, choice, resolve_all, audit, entries_data):
        for data in entries_data:
            audit_log.append(
                session_id=(audit or {}).get("session_id", ""),
                session_key=(audit or {}).get("session_key", session_key),
                choice=choice,
                resolve_all=resolve_all,
                credential=(audit or {}).get("credential", "shared"),
                device_id=(audit or {}).get("device_id"),
                device_name=(audit or {}).get("device_name"),
                token_prefix=(audit or {}).get("token_prefix"),
                command_preview=audit_log._build_command_preview(data),
            )

    if not any(
        getattr(obs, "__name__", "") == "_audit_resolution"
        for obs in _approval._RESOLVE_OBSERVERS
    ):
        _approval._RESOLVE_OBSERVERS.append(_audit_resolution)


def _wire_token_auth() -> None:
    """Register the per-device token registry on the S5 token-auth seam."""
    from hermes_cli.dashboard_auth import token_auth

    from . import device_tokens

    def _validate_device(identity: dict) -> bool:
        device_id = identity.get("device_id")
        # Identities without a device_id aren't ours — leave them alone.
        if not device_id:
            return True
        return device_tokens.is_device_active(device_id)

    def _observe_socket(action: str, identity: dict, ws) -> None:
        device_id = identity.get("device_id")
        if not device_id:
            return
        if action == "register":
            device_tokens.register_ws_socket(device_id, ws)
        elif action == "deregister":
            device_tokens.deregister_ws_socket(device_id, ws)

    if device_tokens.match not in token_auth.TOKEN_AUTHENTICATORS:
        token_auth.TOKEN_AUTHENTICATORS.append(device_tokens.match)
        token_auth.IDENTITY_VALIDATORS.append(_validate_device)
        token_auth.SOCKET_OBSERVERS.append(_observe_socket)


def register(ctx) -> None:
    """Stock plugin entry point — wire the gateway seams + CLI command."""
    try:
        from . import broadcast, push_engine

        broadcast.activate()
        push_engine.activate()
    except Exception:
        # Never break host startup on a wiring failure; the gateway simply
        # behaves like stock (no fan-out, no push) and logs why.
        _log.warning("hermes-mobile: seam wiring failed", exc_info=True)
    try:
        from . import kanban_spec_guard

        kanban_spec_guard.activate(ctx)
    except Exception:
        # Spec enforcement is safety-critical for agent-created cards, but a
        # broken plugin hook must not take down the host process.
        _log.warning("hermes-mobile: kanban-spec guard wiring failed", exc_info=True)
    try:
        _wire_token_auth()
    except Exception:
        # Without this wiring the dashboard simply doesn't accept device
        # tokens (shared-token auth is untouched).
        _log.warning("hermes-mobile: token-auth wiring failed", exc_info=True)
    try:
        _wire_approval_audit()
    except Exception:
        _log.warning("hermes-mobile: approval-audit wiring failed", exc_info=True)
    try:
        ctx.register_cli_command(
            name="mobile-pair",
            help="Pair the HermesMobile iOS app via a QR code",
            setup_fn=_setup_mobile_pair_parser,
            handler_fn=_cmd_mobile_pair,
            description=(
                "Print a hermesapp://pair deep link and an in-terminal QR "
                "code so the HermesMobile app can scan it to pair."
            ),
        )
    except Exception:
        _log.warning("hermes-mobile: CLI registration failed", exc_info=True)
