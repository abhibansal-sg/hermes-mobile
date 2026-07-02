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


def _registry_attr(module, attr: str, seam: str):
    """Return an appendable core registry, or ``None`` while it is late-bound."""
    registry = getattr(module, attr, None)
    if registry is None:
        _log.debug("hermes-mobile: %s registry %s not bound yet", seam, attr)
        return None
    if not hasattr(registry, "append") or not hasattr(registry, "__iter__"):
        _log.debug(
            "hermes-mobile: %s registry %s is not appendable: %r",
            seam,
            attr,
            registry,
        )
        return None
    return registry


def _contains_callback(registry, callback) -> bool:
    """Identity-or-qualified-name membership for stable idempotent wiring."""
    if callback in registry:
        return True
    callback_name = getattr(callback, "__name__", "")
    callback_module = getattr(callback, "__module__", "")
    return bool(
        callback_name
        and any(
            getattr(existing, "__name__", "") == callback_name
            and getattr(existing, "__module__", "") == callback_module
            for existing in registry
        )
    )


def _append_unique(module, attr: str, callback, seam: str) -> bool:
    """Append ``callback`` when a core registry is currently bound.

    Core observer-list attributes can be late-bound during plugin discovery.
    Missing/``None`` registries are not created here; the next register/activate
    pass retries and wires the callback once core has restored the seam.
    """
    registry = _registry_attr(module, attr, seam)
    if registry is None:
        return False
    if not _contains_callback(registry, callback):
        registry.append(callback)
    return True


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

    _append_unique(_approval, "_RESOLVE_OBSERVERS", _audit_resolution, "approval-audit")


def _validate_device(identity: dict) -> bool:
    from . import device_tokens

    device_id = identity.get("device_id")
    # Identities without a device_id aren't ours — leave them alone.
    if not device_id:
        return True
    return device_tokens.is_device_active(device_id)


def _observe_socket(action: str, identity: dict, ws) -> None:
    from . import device_tokens

    device_id = identity.get("device_id")
    if not device_id:
        return
    if action == "register":
        device_tokens.register_ws_socket(device_id, ws)
    elif action == "deregister":
        device_tokens.deregister_ws_socket(device_id, ws)


def _wire_token_auth() -> None:
    """Register the per-device token registry on the S5 token-auth seam."""
    from hermes_cli.dashboard_auth import token_auth

    from . import device_tokens

    _append_unique(token_auth, "TOKEN_AUTHENTICATORS", device_tokens.match, "token-auth")
    _append_unique(token_auth, "IDENTITY_VALIDATORS", _validate_device, "token-auth")
    _append_unique(token_auth, "SOCKET_OBSERVERS", _observe_socket, "token-auth")


def register(ctx) -> None:
    """Stock plugin entry point — wire the gateway seams + CLI command."""
    try:
        from . import broadcast, push_engine
    except Exception:
        _log.warning("hermes-mobile: seam module import failed", exc_info=True)
        broadcast = None
        push_engine = None
    if broadcast is not None:
        try:
            broadcast.activate()
        except Exception:
            # Never break host startup on a wiring failure; the gateway simply
            # behaves like stock (no fan-out) and logs why.
            _log.warning("hermes-mobile: broadcast seam wiring failed", exc_info=True)
    if push_engine is not None:
        try:
            push_engine.activate()
        except Exception:
            # Never break host startup on a wiring failure; the gateway simply
            # behaves like stock (no push) and logs why.
            _log.warning("hermes-mobile: push seam wiring failed", exc_info=True)
    try:
        from . import kanban_spec_guard

        kanban_spec_guard.activate(ctx)
    except Exception:
        # Spec enforcement is safety-critical for agent-created cards, but a
        # broken plugin hook must not take down the host process.
        _log.warning("hermes-mobile: kanban-spec guard wiring failed", exc_info=True)
    try:
        from . import ios_turn_context

        ios_turn_context.activate(ctx)
    except Exception:
        # Mobile formatting guidance is optional; a hook wiring failure must
        # never take down the host process or affect non-mobile sessions.
        _log.warning("hermes-mobile: iOS turn-context wiring failed", exc_info=True)
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
