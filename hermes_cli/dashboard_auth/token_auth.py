from __future__ import annotations
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

# --- upstream token-route gating (merged 2026-07-02, disjoint symbols) ---
"""Route-agnostic non-interactive (bearer-token) auth seam for the dashboard.

This is the generic API-token capability (decisions.md Q-C): a reusable seam
that ANY service-to-service / machine-credential provider plugs into, NOT a
drain-specific hook. The drain bearer-secret plugin is merely the first
consumer.

How it fits the existing auth framework:

  * The interactive gate (``gated_auth_middleware``) authenticates a human
    via a session cookie on every non-public route. A service caller has no
    cookie — it presents a bearer token in the ``Authorization`` header on a
    single request. That is what this seam verifies.

  * A route opts in by registering its exact path via
    :func:`register_token_route`. Only registered paths are token-authable;
    everything else is untouched, so this can never accidentally widen the
    auth surface of an existing route.

  * :func:`token_auth_middleware` runs OUTERMOST (installed last in
    ``web_server.py``). For a token route it fully owns the auth decision:
    authenticate via the stacked token providers, attach the verified
    :class:`~hermes_cli.dashboard_auth.base.TokenPrincipal` to
    ``request.state.token_principal`` + set ``request.state.token_authenticated``,
    and pass through; otherwise reject (401 unauthenticated, or 503 when a
    provider's backing store was unreachable). The downstream cookie/session
    gates honour ``token_authenticated`` and skip enforcement, so a
    token-authed service request is never bounced to ``/login``.

  * Fails closed: a token route with no registered token provider, no token,
    or an unrecognised token gets 401 — never an open pass-through.

Provider stacking mirrors ``verify_session``: each ``supports_token`` provider
is consulted in registration order until one returns a principal. A provider
that doesn't recognise the token returns ``None`` and the seam moves on; a
provider whose backing store is unreachable raises ``ProviderError``, which the
seam remembers and surfaces as 503 only if NO provider accepts the token.
"""

import logging
import threading
from typing import Awaitable, Callable, Optional, Tuple

from fastapi import Request
from fastapi.responses import JSONResponse, Response

from hermes_cli.dashboard_auth import list_token_providers
from hermes_cli.dashboard_auth.audit import AuditEvent, audit_log
from hermes_cli.dashboard_auth.base import ProviderError, TokenPrincipal

_log = logging.getLogger(__name__)

# Exact paths that accept non-interactive bearer-token auth. A route registers
# itself here at import/startup; the seam only acts on registered paths.
_token_routes: set[str] = set()
_lock = threading.Lock()


def register_token_route(path: str) -> None:
    """Mark ``path`` (exact match) as token-authable.

    Idempotent. Call at module import / app setup so the seam knows which
    routes to guard. Registering a route does NOT make it public — it makes
    it authenticate by token instead of by session cookie.
    """
    with _lock:
        _token_routes.add(path)


def is_token_route(path: str) -> bool:
    """True if ``path`` was registered as token-authable (exact match)."""
    with _lock:
        return path in _token_routes


def clear_token_routes() -> None:
    """Test-only: drop all registered token routes."""
    with _lock:
        _token_routes.clear()


def _client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for", "")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else ""


def extract_bearer_token(request: Request) -> str:
    """Return the bearer token from the ``Authorization`` header, or "".

    Accepts ``<scheme> <token>`` where scheme is "bearer" (case-insensitive).
    Returns an empty string for a missing/malformed header or a non-bearer
    scheme — the caller treats "" as "no token presented".
    """
    auth = request.headers.get("authorization", "")
    parts = auth.split(" ", 1)
    if len(parts) == 2 and parts[0].strip().lower() == "bearer":
        return parts[1].strip()
    return ""


def authenticate_token(
    request: Request,
) -> Tuple[Optional[TokenPrincipal], Optional[str]]:
    """Try every token provider against the request's bearer token.

    Returns ``(principal, unreachable_provider_name)``:
      * ``(TokenPrincipal, None)`` — a provider recognised and accepted the token.
      * ``(None, None)`` — no token, or no provider recognised it (reject 401).
      * ``(None, name)`` — no provider accepted it AND at least one provider's
        backing store was unreachable (the caller surfaces 503, not 401, so a
        transient outage doesn't read as "bad credentials").

    Never raises: a provider ``ProviderError`` is caught and remembered.
    """
    token = extract_bearer_token(request)
    if not token:
        return None, None
    unreachable: Optional[str] = None
    for provider in list_token_providers():
        try:
            principal = provider.verify_token(token=token)
        except ProviderError as e:
            _log.warning(
                "dashboard-auth: token provider %r unreachable during verify: %s",
                provider.name, e,
            )
            if unreachable is None:
                unreachable = provider.name
            continue
        except Exception as e:  # noqa: BLE001 — a buggy provider must not 500 the gate
            _log.warning(
                "dashboard-auth: token provider %r raised during verify: %s",
                provider.name, e,
            )
            continue
        if principal is not None:
            return principal, None
    return None, unreachable


async def token_auth_middleware(
    request: Request,
    call_next: Callable[[Request], Awaitable[Response]],
) -> Response:
    """Outermost auth seam for token-authable routes.

    No-op pass-through for any path not registered via
    :func:`register_token_route`. For a registered path, token auth is the
    only accepted scheme:

      * valid token  → attach principal + ``token_authenticated`` flag, pass through.
      * unreachable  → 503 (provider backing store down; not "bad credentials").
      * otherwise    → 401 unauthenticated.

    Runs before the cookie/session gates (installed last in ``web_server.py``).
    The cookie gates honour ``request.state.token_authenticated`` and skip
    enforcement, so a token-authed request is never redirected to ``/login``.
    """
    path = request.url.path
    if not is_token_route(path):
        return await call_next(request)

    principal, unreachable = authenticate_token(request)
    if principal is not None:
        request.state.token_principal = principal
        request.state.token_authenticated = True
        return await call_next(request)

    if unreachable:
        audit_log(
            AuditEvent.TOKEN_AUTH_FAILURE,
            provider=unreachable,
            reason="provider_unreachable",
            path=path,
            ip=_client_ip(request),
        )
        return JSONResponse(
            {"detail": f"Auth provider {unreachable!r} unreachable"},
            status_code=503,
        )

    audit_log(
        AuditEvent.TOKEN_AUTH_FAILURE,
        reason="no_provider_recognises_token",
        path=path,
        ip=_client_ip(request),
    )
    return JSONResponse(
        {"error": "unauthenticated", "detail": "Unauthorized"},
        status_code=401,
    )
