"""Pluggable bearer-token authenticators for the dashboard (seam S5).

The OAuth provider registry (:mod:`hermes_cli.dashboard_auth.registry`)
covers browser login flows; it has no notion of header/bearer credentials.
This module is the complementary seam for *machine* credentials: plugins
register callables here and the dashboard's REST and WebSocket auth gates
consult them AFTER the built-in shared-token checks. A registered
authenticator can therefore only ever ACCEPT additional credentials — it can
never reject the shared token (which already returned before the loop runs).

Shipped consumer: the hermes-mobile plugin registers its per-device token
registry (``plugins/hermes-mobile/device_tokens.py``) so phones authenticate
with revocable per-device tokens. See CONTRACT-DEPATCH.md seam S5; shaped as
the "pluggable dashboard token auth" upstream-PR candidate.

Surface
-------
* ``TOKEN_AUTHENTICATORS`` — ``fn(token: str) -> Optional[dict]``. First
  non-None wins; the returned *identity* dict is stashed on
  ``request.state.device`` / ``ws.state.device`` for scope checks, audit
  attribution, and ticket minting. Implementations must be timing-safe and
  must never raise.
* ``IDENTITY_VALIDATORS`` — ``fn(identity: dict) -> bool``. False means the
  identity has been revoked/deactivated since auth; long-lived sockets are
  closed. With no validators registered an identity stays valid.
* ``SOCKET_OBSERVERS`` — ``fn(action: str, identity: dict, ws) -> None`` with
  action in ``{"register", "deregister"}``. Lets a plugin index live sockets
  per identity so revocation can cut them immediately.
"""

from __future__ import annotations

import logging
from typing import Any, Callable, Dict, List, Optional

_log = logging.getLogger(__name__)

TOKEN_AUTHENTICATORS: List[Callable[[str], Optional[Dict[str, Any]]]] = []
IDENTITY_VALIDATORS: List[Callable[[Dict[str, Any]], bool]] = []
SOCKET_OBSERVERS: List[Callable[[str, Dict[str, Any], Any], None]] = []


def match_token(token: str) -> Optional[Dict[str, Any]]:
    """Return the first registered authenticator's identity for *token*.

    Never raises; a misbehaving authenticator is logged and skipped. ``None``
    means "not one of mine" — it NEVER implies any other credential is
    invalid.
    """
    if not token:
        return None
    for auth in list(TOKEN_AUTHENTICATORS):
        try:
            identity = auth(token)
        except Exception:
            _log.debug("token authenticator errored", exc_info=True)
            continue
        if isinstance(identity, dict):
            return identity
    return None


def identity_active(identity: Any) -> bool:
    """True while *identity* (a dict from :func:`match_token`) is still valid.

    Consulted on long-lived connections so a revoked credential loses access
    without waiting for a reconnect. Fail-open per validator error (a broken
    plugin must not cut every session), fail-closed on an explicit False.
    """
    if not isinstance(identity, dict):
        return False
    for validator in list(IDENTITY_VALIDATORS):
        try:
            if not validator(identity):
                return False
        except Exception:
            _log.debug("identity validator errored", exc_info=True)
    return True


def notify_socket(action: str, identity: Dict[str, Any], ws: Any) -> None:
    """Tell observers a credentialed WS socket was (de)registered."""
    for obs in list(SOCKET_OBSERVERS):
        try:
            obs(action, identity, ws)
        except Exception:
            _log.debug("socket observer errored", exc_info=True)
