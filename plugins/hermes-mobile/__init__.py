"""Hermes Mobile notification edge for a stock Hermes gateway.

The phone connects directly to the stock gateway. This optional plugin adds
APNs delivery, device registration, and idempotency receipts through public
Hermes plugin seams. It does not observe or transform gateway frames.

Modules:

* ``push_engine`` — stock lifecycle hooks → relay/APNs + Live Activities.
* ``prompt_receipts`` — profile-scoped SQLite idempotency receipts for
  ID-enabled ``prompt.submit`` requests.
* ``dashboard/api.py`` — REST routes, auto-mounted by the dashboard plugin
  system at ``/api/plugins/hermes-mobile/`` (upload, approvals, devices,
  fs browse, push registration).

``register(ctx)`` imports the gateway modules and registers the stock hooks.
In CLI-only processes the gateway-specific wiring is inert.
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


def _identity_owns_session(identity: dict, session_id: str) -> bool | None:
    device_id = identity.get("device_id") if isinstance(identity, dict) else None
    if not device_id:
        return None
    from . import device_tokens

    owner = device_tokens.device_identity_for_session(session_id)
    return isinstance(owner, dict) and owner.get("device_id") == device_id


def _wire_token_auth() -> None:
    """Register the per-device token registry on the S5 token-auth seam."""
    from hermes_cli.dashboard_auth import token_auth

    from . import device_tokens

    _append_unique(token_auth, "TOKEN_AUTHENTICATORS", device_tokens.match, "token-auth")
    _append_unique(token_auth, "IDENTITY_VALIDATORS", _validate_device, "token-auth")
    _append_unique(token_auth, "SOCKET_OBSERVERS", _observe_socket, "token-auth")
    _append_unique(
        token_auth,
        "SESSION_OWNERSHIP_CHECKERS",
        _identity_owns_session,
        "token-auth",
    )


def _wire_prompt_receipts() -> bool:
    """Register idempotency when the host exposes the optional receipt seam."""
    from tui_gateway import server

    from .prompt_receipts import PROVIDER

    register_provider = getattr(server, "register_prompt_receipt_provider", None)
    if not callable(register_provider):
        return False
    register_provider(PROVIDER)
    return True


def register(ctx) -> None:
    """Stock plugin entry point — wire notification and receipt seams."""
    try:
        from . import push_engine
    except Exception:
        _log.warning("hermes-mobile: push module import failed", exc_info=True)
        push_engine = None
    if push_engine is not None:
        try:
            push_engine.activate(ctx)
        except Exception:
            # Never break host startup on a wiring failure; the gateway simply
            # behaves like stock (no push) and logs why.
            _log.warning("hermes-mobile: push seam wiring failed", exc_info=True)
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
        _wire_prompt_receipts()
    except Exception:
        # Plugin-disabled and wiring-failure behavior is deliberately stock:
        # the empty core registry makes client_message_id a no-op.
        _log.warning("hermes-mobile: prompt-receipt wiring failed", exc_info=True)
