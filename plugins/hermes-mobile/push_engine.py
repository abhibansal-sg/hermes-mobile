"""
hermes-mobile plugin — stock lifecycle notification adapter.

Notification intake uses only public Hermes v0.19 plugin hooks. The adapter
normalizes those lifecycle callbacks into the event shapes already consumed by
this module; alert delivery remains owned by the hosted push relay through
``relay_client``. No gateway frame-observer or event-fan-out seam is required
for notification delivery.

The ``/push/*`` REST routes live in this plugin's ``dashboard/api.py`` mounted
at ``/api/plugins/hermes-mobile/push/...``. This module deliberately does not
keep a second device-token registry or a second alert APNs sender.

Direct APNs remains only for ActivityKit remote updates because the relay does
not yet expose a Live Activity token/update contract. That path is dormant
unless the following legacy APNs credentials are configured:

  ============================  ====================================================
  ``HERMES_PUSH_ENABLED``       truthy ("1", "true", "yes", "on") to arm the sender
  ``HERMES_APNS_KEY_FILE``      path to the ``.p8`` token-signing key (AuthKey_*.p8)
  ``HERMES_APNS_KEY_ID``        10-char Key ID from the Apple Developer portal
  ``HERMES_APNS_TEAM_ID``       10-char Team ID
  ``HERMES_APNS_TOPIC``         APNs topic / bundle id (default "ai.hermes.app")
  ``HERMES_APNS_USE_SANDBOX``   truthy → api.sandbox.push.apple.com (default prod)
  ============================  ====================================================

Auth uses a JWT (ES256) provider token per the APNs token-based authentication
spec — built once and reused for up to ~50 minutes (Apple rejects tokens older
than 60 minutes and refuses tokens minted more than once every 20 minutes).

Live Activity tokens live in ``<HERMES_HOME>/live_activity_tokens.json`` and
are pruned when APNs reports that they are dead.

Optional deps (PyJWT + cryptography) are imported lazily; importing this module
never fails. If they are absent the sender degrades to a no-op and the JWT
builder raises :class:`PushDependencyError` with the pip install hint.
"""

from __future__ import annotations

import atexit
import copy
import hashlib
import json
import logging
import os
import queue
import re
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from utils import atomic_json_write

_log = logging.getLogger(__name__)

# Default APNs bundle/topic. Matches the iOS app bundle id.
DEFAULT_TOPIC = "ai.hermes.app"

# APNs hosts (HTTP/2). Sandbox is used for development builds / TestFlight
# pushes signed with a development APNs environment.
_APNS_HOST_PROD = "api.push.apple.com"
_APNS_HOST_SANDBOX = "api.sandbox.push.apple.com"
_APNS_PORT = 443

# A provider token must be refreshed periodically. Apple rejects tokens older
# than 1h and tokens reminted more often than every 20m, so 50m is the sweet
# spot: comfortably under the hard cap, comfortably over the mint floor.
_JWT_REFRESH_SECONDS = 50 * 60

# Truthy env strings (kept local so this module has no hard dependency on the
# wider hermes utils package — it must be importable from tests in isolation).
_TRUTHY = frozenset({"1", "true", "yes", "on", "y", "t"})


class PushDependencyError(RuntimeError):
    """Raised when PyJWT / cryptography are required but unavailable.

    The message carries the exact pip install command so callers (and tests)
    can surface a usable remediation rather than a bare ImportError.
    """


PIP_INSTALL_HINT = (
    "APNs push requires PyJWT and cryptography. Install with: "
    "python -m pip install 'pyjwt[crypto]' cryptography"
)


def _is_truthy(value: Optional[str]) -> bool:
    return bool(value) and value.strip().lower() in _TRUTHY


# ---------------------------------------------------------------------------
# Config snapshot (read from env on demand — never cached at import time so
# tests and operators can flip env without reimporting).
# ---------------------------------------------------------------------------

class APNsConfig:
    """Immutable view of the APNs environment at construction time."""

    __slots__ = ("key_file", "key_id", "team_id", "topic", "use_sandbox", "enabled")

    def __init__(
        self,
        *,
        key_file: Optional[str],
        key_id: Optional[str],
        team_id: Optional[str],
        topic: str,
        use_sandbox: bool,
        enabled: bool,
    ) -> None:
        self.key_file = key_file
        self.key_id = key_id
        self.team_id = team_id
        self.topic = topic
        self.use_sandbox = use_sandbox
        self.enabled = enabled

    @classmethod
    def from_env(cls) -> "APNsConfig":
        return cls(
            key_file=os.environ.get("HERMES_APNS_KEY_FILE") or None,
            key_id=os.environ.get("HERMES_APNS_KEY_ID") or None,
            team_id=os.environ.get("HERMES_APNS_TEAM_ID") or None,
            topic=os.environ.get("HERMES_APNS_TOPIC") or DEFAULT_TOPIC,
            use_sandbox=_is_truthy(os.environ.get("HERMES_APNS_USE_SANDBOX")),
            enabled=_is_truthy(os.environ.get("HERMES_PUSH_ENABLED")),
        )

    @property
    def host(self) -> str:
        return _APNS_HOST_SANDBOX if self.use_sandbox else _APNS_HOST_PROD

    def key_file_exists(self) -> bool:
        return bool(self.key_file) and Path(self.key_file).is_file()

    def is_armed(self) -> bool:
        """True iff push is enabled AND credentials are present on disk.

        Topic always has a default, so the gating credentials are: enabled
        flag, key file (existing), key id, and team id. Missing any → no-op.
        """
        return (
            self.enabled
            and self.key_file_exists()
            and bool(self.key_id)
            and bool(self.team_id)
        )


# ---------------------------------------------------------------------------
# ActivityKit APNs builders.
# ---------------------------------------------------------------------------

def build_provider_jwt(
    *,
    key_pem: str,
    key_id: str,
    team_id: str,
    issued_at: Optional[int] = None,
) -> str:
    """Build a signed APNs provider JWT (ES256).

    ``key_pem`` is the PEM/text contents of the ``.p8`` signing key. ``key_id``
    becomes the JWT header ``kid``; ``team_id`` becomes the ``iss`` claim and
    ``issued_at`` (epoch seconds, defaults to now) the ``iat`` claim. APNs
    derives expiry from ``iat`` (must be < 1h old), so no ``exp`` is emitted.

    Raises :class:`PushDependencyError` if PyJWT is unavailable.
    """
    try:
        import jwt  # PyJWT
    except ImportError as exc:  # pragma: no cover - exercised via skip in tests
        raise PushDependencyError(PIP_INSTALL_HINT) from exc

    iat = int(issued_at if issued_at is not None else time.time())
    return jwt.encode(
        {"iss": team_id, "iat": iat},
        key_pem,
        algorithm="ES256",
        headers={"alg": "ES256", "kid": key_id},
    )


_CORRELATED_EVENTS = {
    "approval.request": "approval",
    "clarify.request": "clarify",
    "message.complete": "turn_complete",
}


def _gateway_scope() -> str:
    """Stable, non-secret namespace for one gateway/profile installation."""
    try:
        scope = str(_la_registry_path().parent.resolve())
    except Exception:
        scope = str(_la_registry_path().parent)
    return "gw_" + hashlib.sha256(scope.encode("utf-8")).hexdigest()[:16]


def _active_turn_identity(sid: str) -> tuple[str, str]:
    """Return the current stable turn/tool identities when event intake has them."""
    turn_id = ""
    tool_call_id = ""
    try:
        from tools import approval as approval_module

        turn_id = str(approval_module._approval_turn_id.get() or "").strip()
        tool_call_id = str(
            approval_module._approval_tool_call_id.get() or ""
        ).strip()
    except Exception:
        pass
    session = _gw_sessions().get(sid) or {}
    agent = session.get("agent") if isinstance(session, dict) else None
    if not turn_id:
        turn_id = str(getattr(agent, "_current_turn_id", "") or "").strip()
    return turn_id, tool_call_id


def _stable_event_identity(event: str, sid: str, data: dict) -> tuple[str, str]:
    """Return (logical identity, turn id) without inventing a random fallback."""
    turn_id, tool_call_id = _active_turn_identity(sid)
    if event == "approval.request":
        explicit = data.get("approval_id") or data.get("id") or data.get("request_id")
        identity = str(explicit or "").strip()
        if not identity:
            identity = ":".join(part for part in (turn_id, tool_call_id) if part)
    elif event == "clarify.request":
        identity = str(data.get("request_id") or "").strip()
    else:
        identity = str(data.get("turn_id") or turn_id or "").strip()
    if not identity:
        # Legacy/minimal emitters may not carry an agent turn context. A stable
        # content digest is deliberately deterministic (never UUID/random) and
        # keeps identical re-emissions of the same logical payload correlated.
        canonical = json.dumps(data, sort_keys=True, separators=(",", ":"), default=str)
        identity = "content_" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:24]
    return identity, turn_id


def enrich_correlated_event(event: str, sid: str, payload: dict | None) -> dict | None:
    """Stamp one stable identity into both live frames and downstream APNs."""
    kind = _CORRELATED_EVENTS.get(event)
    if kind is None:
        return payload
    data = dict(payload or {})
    identity, turn_id = _stable_event_identity(event, sid, data)
    correlation_source = f"{kind}\0{sid}\0{identity}"
    event_id = "evt_" + hashlib.sha256(
        correlation_source.encode("utf-8")
    ).hexdigest()[:32]
    # Preserve the identity stamped by the pre-emit seam.  The worker may be
    # called directly, but must not recalculate a different ID for an already
    # correlated live frame.
    data.setdefault("event_id", event_id)
    data.setdefault("gateway_scope", _gateway_scope())
    if turn_id:
        data.setdefault("turn_id", turn_id)
    if event == "approval.request":
        # The approval itself must have a server identity. iOS may display an
        # id-less legacy prompt, but it must never synthesize a UUID for dedupe.
        data.setdefault("approval_id", identity)
    elif event == "clarify.request":
        # Keep the request identity explicit in every transport, including
        # legacy emitters that omitted request_id at intake.
        data.setdefault("request_id", identity)
    elif event == "message.complete":
        # A completion is correlated to its turn even when the caller invokes
        # the push worker directly and bypasses the pre-emit transform.
        data.setdefault("turn_id", identity)
    return data


def build_manifest_invalidation_payload(
    scope: str, revision: int, reason: str
) -> Dict[str, Any]:
    """Build the frozen data-free background sync envelope."""
    return {
        "aps": {"content-available": 1},
        "sync": {"scope": scope, "revision": revision, "reason": reason},
    }


# ---------------------------------------------------------------------------
# Live Activity (ActivityKit) remote-update payload + headers.
#
# A Live Activity push targets the activity's own push token (NOT the app's
# device token) and uses a dedicated apns-push-type/topic. The content-state
# keys MUST match HermesTurnAttributes.ContentState exactly (Swift Codable):
#   phase: String, toolName: String?, elapsedSeconds: Int, needsApproval: Bool,
#   startedAtEpochSeconds: Double?
# ---------------------------------------------------------------------------

# Per the contract: the Live Activity topic is the bundle id suffixed with the
# ActivityKit push-type marker. Derived from whatever alert topic is in force
# so a custom HERMES_APNS_TOPIC keeps the two in lockstep.
_LIVE_ACTIVITY_TOPIC_SUFFIX = ".push-type.liveactivity"


def live_activity_topic(base_topic: str = DEFAULT_TOPIC) -> str:
    """APNs topic for Live Activity pushes: ``<bundle id>.push-type.liveactivity``."""
    return f"{base_topic}{_LIVE_ACTIVITY_TOPIC_SUFFIX}"


def build_live_activity_headers(
    *,
    provider_jwt: str,
    topic: str = DEFAULT_TOPIC,
    priority: int = 10,
    expiration: int = 0,
) -> Dict[str, str]:
    """Build the APNs HTTP/2 headers for a Live Activity update/end push.

    ``apns-push-type`` is ``liveactivity`` and ``apns-topic`` is the
    ``.push-type.liveactivity`` topic derived from the alert topic.
    """
    return {
        "authorization": f"bearer {provider_jwt}",
        "apns-topic": live_activity_topic(topic),
        "apns-push-type": "liveactivity",
        "apns-priority": str(priority),
        "apns-expiration": str(expiration),
    }


def build_live_activity_payload(
    content_state: Dict[str, Any],
    *,
    end: bool = False,
    timestamp: Optional[int] = None,
    dismissal_date: Optional[int] = None,
) -> Dict[str, Any]:
    """Shape the APNs payload for a Live Activity update or end event.

    Produces ``{"aps": {"timestamp", "event", "content-state", ...}}`` per the
    ActivityKit remote-update spec. ``end`` flips the event to ``"end"`` and
    carries a ``dismissal-date`` (defaults to ``timestamp`` — dismiss now).

    ``content-state`` is passed through verbatim; callers are responsible for
    using the exact ``HermesTurnAttributes.ContentState`` Codable field names.
    """
    now = int(timestamp if timestamp is not None else time.time())
    aps: Dict[str, Any] = {
        "timestamp": now,
        "event": "end" if end else "update",
        "content-state": content_state,
    }
    if end:
        aps["dismissal-date"] = int(
            dismissal_date if dismissal_date is not None else now
        )
    return {"aps": aps}


# ---------------------------------------------------------------------------
# Shared token validation and Live Activity APNs error handling.
# Alert-device registration and delivery are relay-owned.
# ---------------------------------------------------------------------------

_MIN_TOKEN_LEN = 32
_MAX_TOKEN_LEN = 200


def _normalize_token(token: str) -> Optional[str]:
    """Return a lowercased hex device token, or None if it is malformed."""
    if not isinstance(token, str):
        return None
    value = token.strip().lower().replace(" ", "")
    if not (_MIN_TOKEN_LEN <= len(value) <= _MAX_TOKEN_LEN):
        return None
    try:
        int(value, 16)
    except ValueError:
        return None
    return value


def _default_env() -> str:
    return (
        "sandbox"
        if _is_truthy(os.environ.get("HERMES_APNS_USE_SANDBOX"))
        else "production"
    )


PUSH_EVENT_KINDS = (
    "approval",
    "clarify",
    "turn_complete",
    "turn_error",
    "background_done",
)


_EVICTABLE_APNS_REASONS = frozenset({"BadDeviceToken", "Unregistered"})


def _apns_reason(response_text: str) -> Optional[str]:
    try:
        parsed = json.loads(response_text)
    except (ValueError, TypeError):
        return None
    if isinstance(parsed, dict):
        reason = parsed.get("reason")
        if isinstance(reason, str) and reason:
            return reason
    return None


def _is_dead_token(status: int, reason: Optional[str]) -> bool:
    return status == 410 or reason in _EVICTABLE_APNS_REASONS


# ---------------------------------------------------------------------------
# Live Activity token registry — JSON file at
# <HERMES_HOME>/live_activity_tokens.json, keyed by session_id.
#
# Live Activity pushes target the *activity's* own rotating token, not the
# relay-owned app device token. We therefore key by session_id and UPSERT on
# rotation. Dead tokens are pruned from this local ActivityKit-only registry.
# ---------------------------------------------------------------------------

_la_registry_lock = threading.Lock()
_LA_REGISTRY_MAX_AGE_SECONDS = 24 * 60 * 60


def _la_registry_path() -> Path:
    """Resolve the Live Activity token registry path (sibling of push_tokens)."""
    try:
        from hermes_cli.config import get_hermes_home

        return get_hermes_home() / "live_activity_tokens.json"
    except Exception:  # pragma: no cover - defensive fallback
        return Path(os.path.expanduser("~/.hermes")) / "live_activity_tokens.json"


def _load_la_registry() -> Dict[str, Dict[str, Any]]:
    """Load the LA registry as ``{session_id: {token, env, registered_at}}``."""
    path = _la_registry_path()
    try:
        raw = path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError):
        return {}
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        _log.warning("live_activity_tokens.json is corrupt; treating as empty")
        return {}
    if not isinstance(data, dict):
        return {}
    out: Dict[str, Dict[str, Any]] = {}
    for sid, entry in data.items():
        if isinstance(sid, str) and isinstance(entry, dict) and isinstance(
            entry.get("token"), str
        ):
            out[sid] = entry
    return out


def _save_la_registry(entries: Dict[str, Dict[str, Any]]) -> None:
    path = _la_registry_path()
    try:
        # Registry holds ActivityKit push tokens; write atomically as 0600.
        atomic_json_write(path, entries, indent=2, mode=0o600)
    except OSError as exc:
        _log.warning("Could not persist live_activity_tokens.json: %s", exc)


def prune_live_activity_tokens(
    *, max_age_seconds: Optional[float] = None, now: Optional[float] = None
) -> int:
    """Drop Live Activity token entries older than ``max_age_seconds``.

    A Live Activity token belongs to one in-flight activity. Normal close/delete
    paths unregister explicitly, but this GC prevents abandoned clients from
    leaving dead activity tokens in the registry forever.
    """
    try:
        max_age = float(
            _LA_REGISTRY_MAX_AGE_SECONDS
            if max_age_seconds is None
            else max_age_seconds
        )
    except (TypeError, ValueError):
        return 0
    if max_age <= 0:
        return 0
    cutoff = float(time.time() if now is None else now) - max_age
    with _la_registry_lock:
        entries = _load_la_registry()
        kept: Dict[str, Dict[str, Any]] = {}
        removed = 0
        for sid, entry in entries.items():
            try:
                registered_at = float(entry.get("registered_at"))
            except (TypeError, ValueError):
                registered_at = 0.0
            if registered_at <= cutoff:
                removed += 1
            else:
                kept[sid] = entry
        if removed:
            _save_la_registry(kept)
        return removed


def register_live_activity_token(
    session_id: str,
    token: str,
    env: str = "",
    device_id: Optional[str] = None,
) -> bool:
    """Upsert a Live Activity push token for ``session_id``.

    Tokens rotate over an activity's lifetime; re-registering the same
    session_id replaces the stored token (and env). Returns False if the
    session_id or token is malformed.
    """
    if not isinstance(session_id, str) or not session_id.strip():
        return False
    normalized = _normalize_token(token)
    if normalized is None:
        return False
    environment = env if env in ("sandbox", "production") else _default_env()
    with _la_registry_lock:
        entries = _load_la_registry()
        entry = {
            "token": normalized,
            "env": environment,
            "registered_at": time.time(),
        }
        if isinstance(device_id, str) and device_id.strip():
            entry["device_id"] = device_id.strip()
        entries[session_id] = entry
        _save_la_registry(entries)
    return True


def unregister_live_activity_token(session_id: str) -> bool:
    """Remove the Live Activity token for ``session_id``. True if one existed."""
    if not isinstance(session_id, str):
        return False
    with _la_registry_lock:
        entries = _load_la_registry()
        if session_id not in entries:
            return False
        entries.pop(session_id, None)
        _save_la_registry(entries)
    return True


def live_activity_token_for(session_id: str) -> Optional[Tuple[str, str]]:
    """Return ``(token, env)`` for ``session_id``, or None if not registered."""
    prune_live_activity_tokens()
    entry = _load_la_registry().get(session_id)
    if not entry:
        return None
    token = _normalize_token(entry.get("token", ""))
    if not token:
        return None
    env = entry.get("env")
    if env not in ("sandbox", "production"):
        env = _default_env()
    return token, env


def live_activity_device_for(session_id: str) -> Optional[str]:
    """Return the device id that registered ``session_id``'s LA token, if any."""
    prune_live_activity_tokens()
    entry = _load_la_registry().get(session_id)
    if not isinstance(entry, dict):
        return None
    device_id = entry.get("device_id")
    if isinstance(device_id, str) and device_id.strip():
        return device_id.strip()
    return None


def _drop_la_token(session_id: str) -> None:
    """Prune a session's LA token (called on 410 Unregistered / 400 BadDeviceToken)."""
    with _la_registry_lock:
        entries = _load_la_registry()
        if entries.pop(session_id, None) is not None:
            _save_la_registry(entries)


# ---------------------------------------------------------------------------
# Provider-JWT cache — minted once, reused across sends until it ages out.
# ---------------------------------------------------------------------------

_jwt_lock = threading.Lock()
_cached_jwt: Optional[str] = None
_cached_jwt_at: float = 0.0
_cached_jwt_kid: Optional[str] = None
_cached_jwt_team_id: Optional[str] = None


def _get_provider_jwt(config: APNsConfig) -> str:
    """Return a fresh-enough provider JWT, minting/refreshing as needed.

    Raises PushDependencyError if deps are missing, or OSError if the key file
    can't be read.
    """
    global _cached_jwt, _cached_jwt_at, _cached_jwt_kid, _cached_jwt_team_id
    assert config.key_file and config.key_id and config.team_id
    now = time.time()
    with _jwt_lock:
        fresh = (
            _cached_jwt is not None
            and _cached_jwt_kid == config.key_id
            and _cached_jwt_team_id == config.team_id
            and (now - _cached_jwt_at) < _JWT_REFRESH_SECONDS
        )
        if fresh:
            return _cached_jwt  # type: ignore[return-value]
        key_pem = Path(config.key_file).read_text(encoding="utf-8")
        token = build_provider_jwt(
            key_pem=key_pem,
            key_id=config.key_id,
            team_id=config.team_id,
            issued_at=int(now),
        )
        _cached_jwt = token
        _cached_jwt_at = now
        _cached_jwt_kid = config.key_id
        _cached_jwt_team_id = config.team_id
        return token


# ---------------------------------------------------------------------------
# HTTP/2 sender — one connection per notify() call, reused across all tokens.
# ---------------------------------------------------------------------------

def _send_one(
    conn: Any,
    *,
    device_token: str,
    headers: Dict[str, str],
    body: bytes,
) -> Tuple[int, str]:
    """POST a single push over an open hyper/httpx HTTP/2 connection.

    Returns ``(status_code, response_text)``. Kept separate from :func:`notify`
    so the transport is swappable in tests.
    """
    path = f"/3/device/{device_token}"
    resp = conn.post(path, content=body, headers=headers)
    return resp.status_code, (resp.text or "")


def notify_manifest_invalidation(scope: str, revision: int, reason: str) -> int:
    """Best-effort relay-owned background invalidation; never raises."""
    try:
        from . import relay_client

        payload = build_manifest_invalidation_payload(scope, revision, reason)
        relay_client.send_manifest_invalidation_background(
            payload=payload,
            headers={
                "apns-topic": DEFAULT_TOPIC,
                "apns-push-type": "background",
                "apns-priority": "5",
                "apns-expiration": "0",
                "apns-collapse-id": f"hermes-sync:{scope}"[:64],
            },
        )
        return 1
    except Exception:
        _log.warning("manifest invalidation push failed", exc_info=True)
        return 0


def notify(
    event_type: str,
    title: str,
    body: str,
    payload: Optional[Dict[str, Any]] = None,
    *,
    category: Optional[str] = None,
    expiration: int = 0,
    collapse_id: Optional[str] = None,
    excluding_device_ids: set[str] | None = None,
) -> int:
    """Queue one alert with the push relay. Never raises."""
    del expiration, collapse_id, excluding_device_ids
    try:
        from . import relay_client

        relay_payload = payload if isinstance(payload, dict) else {}
        relay_client.send_event_background(
            kind=relay_client.map_push_kind(event_type),
            session_id=relay_payload.get("session_id"),
            title=title,
            body=body,
            source=relay_payload.get("source"),
            event_type=event_type,
            category=category,
            payload=relay_payload or None,
        )
        return 1
    except Exception:
        _log.debug("relay push notify failed", exc_info=True)
        return 0


def notify_live_activity(
    session_id: str,
    content_state: Dict[str, Any],
    *,
    end: bool = False,
    priority: int = 10,
) -> bool:
    """Send a Live Activity remote update (or end) for ``session_id``.

    Targets the activity's push token registered for this session. Silent
    no-op (returns False) unless push is armed AND a token is registered. The
    token is pruned on APNs ``410 Unregistered`` or ``400 BadDeviceToken``,
    matching alert-token pruning semantics (QA-2 R1). Returns True iff APNs
    accepted the push (HTTP 200). In
    relay mode, returns True only when background relay delivery was kicked off;
    relay delivery failures are surfaced via relay warnings/failure counters.

    ``content_state`` MUST use the ``HermesTurnAttributes.ContentState`` Codable
    field names (``phase``, ``toolName``, ``elapsedSeconds``, ``needsApproval``,
    ``startedAtEpochSeconds``). ``priority`` is 10 for lifecycle/blocking
    transitions and 5 for routine progress updates.

    Never raises: errors are logged and swallowed so a failed LA push can never
    break the calling gateway hook.
    """
    if os.environ.get("HERMES_MOBILE_RELAY_URL"):
        try:
            from . import relay_client
        except Exception:
            _log.debug("relay live activity notify failed", exc_info=True)
            return False
        try:
            relay_client.send_live_activity_background(
                session_id=session_id,
                content_state=content_state,
                end=end,
            )
            return True
        except Exception:
            _log.debug("relay live activity notify failed", exc_info=True)
            return False

    config = APNsConfig.from_env()
    if not config.is_armed():
        _log.debug("live activity: not armed — no-op")
        return False

    reg = live_activity_token_for(session_id)
    if reg is None:
        return False
    token, env = reg

    try:
        import httpx
    except ImportError:
        _log.warning("live activity: httpx unavailable — cannot send (%s)", PIP_INSTALL_HINT)
        return False

    try:
        provider_jwt = _get_provider_jwt(config)
    except PushDependencyError:
        _log.warning("live activity: %s", PIP_INSTALL_HINT)
        return False
    except OSError as exc:
        _log.warning("live activity: cannot read APNs key file: %s", exc)
        return False

    headers = build_live_activity_headers(
        provider_jwt=provider_jwt,
        topic=config.topic,
        priority=priority,
    )
    body_bytes = json.dumps(
        build_live_activity_payload(content_state, end=end)
    ).encode("utf-8")

    env_hosts = {"sandbox": _APNS_HOST_SANDBOX, "production": _APNS_HOST_PROD}
    base_url = f"https://{env_hosts.get(env, config.host)}:{_APNS_PORT}"
    try:
        with httpx.Client(http2=True, base_url=base_url, timeout=10.0) as conn:
            status, text = _send_one(
                conn, device_token=token, headers=headers, body=body_bytes
            )
    except Exception as exc:  # pragma: no cover - connection-level failure
        _log.warning("live activity: APNs send failed: %s", exc)
        return False

    if status == 200:
        return True
    # QA-2 R1: evict on 410 Unregistered AND 400 BadDeviceToken — a dead
    # activity token re-sent every progress tick is the same re-hammer bug.
    reason = _apns_reason(text)
    if _is_dead_token(status, reason):
        _drop_la_token(session_id)
        _log.info("live activity: pruned dead token for session %s (APNs %s%s)",
                  session_id, status, f" {reason}" if reason else "")
        return False
    _log.info("live activity: APNs %s for session %s: %s",
              status, session_id, text[:200])
    return False




# ===========================================================================
# Existing event formatter/delivery machinery, now fed by stock lifecycle
# hooks instead of the gateway's frame-emission path.
#
# ``_gw_sessions()`` is the one adaptation: the moved code read the gateway's
# module-global ``_sessions`` directly; here it is resolved lazily so this
# module stays importable without the gateway.
# ===========================================================================


def _gw_sessions() -> dict:
    """Live gateway session table (lazy; empty when no gateway is loaded)."""
    try:
        from tui_gateway import server as _server

        return _server._sessions
    except Exception:  # pragma: no cover - gateway absent (tests, CLI-only)
        return {}


def _foreground_phone_devices(sid: str, session: dict | None = None) -> set[str]:
    """Phone devices actively displaying this stored session, never desktops."""
    try:
        from . import device_tokens

        stored = str((session or {}).get("session_key") or sid)
        return device_tokens.foreground_device_ids_for_session(stored)
    except Exception:
        _log.debug("foreground device lookup failed", exc_info=True)
        return set()


# Minimum seconds between routine Live Activity remote updates for one session.
# Lifecycle/blocking updates bypass this budget floor so user action and terminal
# state are delivered immediately.
_LIVE_ACTIVITY_THROTTLE_S = 3.0
_LIVE_ACTIVITY_PRIORITY_ROUTINE = 5
_LIVE_ACTIVITY_PRIORITY_IMMEDIATE = 10
_PUSH_QUEUE_MAX = 512
_PUSH_ALERT_EVENTS = frozenset(
    {
        "approval.request",
        "clarify.request",
        "message.complete",
        "error",
        "background.complete",
    }
)
_LIVE_ACTIVITY_EVENTS = frozenset(
    {
        "message.start",
        "tool.start",
        "tool.complete",
        "approval.request",
        "clarify.request",
        "status.update",
        "error",
        "message.complete",
        "session.interrupt",
    }
)
_PUSH_QUEUE: queue.Queue[
    tuple[str, str, dict | None, float, float | None]
] = queue.Queue(
    maxsize=_PUSH_QUEUE_MAX
)
_PUSH_WORKER_LOCK = threading.Lock()
_PUSH_WORKER_STARTED = False
_PUSH_STOP = threading.Event()
_PUSH_TEXT_MAX = 180
_PUSH_SECRET_PATTERNS = (
    re.compile(
        r"(?i)\b(api[_-]?key|token|secret|password|authorization)\b\s*[:=]\s*\S+"
    ),
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{12,}"),
)
_LA_BLOCKING_STATUS_KINDS = frozenset(
    {"approval", "approve", "blocked", "clarify", "input", "prompt", "waiting"}
)


def _is_kanban_worker() -> bool:
    """True when this process is a dispatched Hermes kanban worker.

    The dispatcher pins ``HERMES_KANBAN_TASK`` in the worker's environment
    (board-scoped isolation — see AGENTS.md "Kanban"). Worker turns must not
    spam the user's phone with turn-complete alerts; approval requests still
    push (handled in their own branch of :func:`_process_push_event`).
    """
    return bool(os.environ.get("HERMES_KANBAN_TASK"))


def _push_safe_text(
    value: Any, fallback: str, *, max_chars: int = _PUSH_TEXT_MAX
) -> str:
    """Bound and scrub lock-screen-visible push text."""
    text = str(value if value is not None else fallback)
    text = "".join(" " if ord(ch) < 32 or ord(ch) == 127 else ch for ch in text)
    text = " ".join(text.split()).strip()
    if not text:
        text = fallback
    for pattern in _PUSH_SECRET_PATTERNS:
        text = pattern.sub(
            lambda m: (
                f"{m.group(1)}=[redacted]"
                if m.lastindex
                else "Bearer [redacted]"
            ),
            text,
        )
    if len(text) > max_chars:
        return text[: max(0, max_chars - 3)].rstrip() + "..."
    return text


def _start_push_worker() -> None:
    global _PUSH_WORKER_STARTED
    if _PUSH_WORKER_STARTED:
        return
    with _PUSH_WORKER_LOCK:
        if _PUSH_WORKER_STARTED:
            return
        t = threading.Thread(
            target=_push_worker_loop,
            name="tui-push-worker",
            daemon=True,
        )
        t.start()
        _PUSH_WORKER_STARTED = True


def _enqueue_push_event(
    event: str,
    sid: str,
    payload: dict | None,
    event_time: float | None = None,
    turn_started: float | None = None,
) -> None:
    """Queue APNs work without blocking the JSON-RPC emit path."""
    _start_push_worker()
    queued_payload = copy.deepcopy(payload) if isinstance(payload, dict) else None
    item = (event, sid, queued_payload, event_time or time.time(), turn_started)
    try:
        _PUSH_QUEUE.put_nowait(item)
        return
    except queue.Full:
        pass

    try:
        _PUSH_QUEUE.get_nowait()
        _PUSH_QUEUE.task_done()
    except queue.Empty:
        pass
    try:
        _PUSH_QUEUE.put_nowait(item)
    except queue.Full:
        _log.debug("push queue full; dropping %s for %s", event, sid)


def _push_worker_loop() -> None:
    while not _PUSH_STOP.is_set():
        try:
            event, sid, payload, event_time, turn_started = _PUSH_QUEUE.get(
                timeout=0.5
            )
        except queue.Empty:
            continue
        try:
            _process_push_event(
                event,
                sid,
                payload,
                event_time=event_time,
                turn_started=turn_started,
            )
        finally:
            _PUSH_QUEUE.task_done()


atexit.register(_PUSH_STOP.set)


def _push_approval_enrichment(sid: str, data: dict) -> dict:
    """Build the F2 approval ``hermes`` block: session_id + stored_session_id +
    destructive + approval_title."""
    enriched: dict = {"session_id": sid}
    for key in ("event_id", "gateway_scope", "approval_id", "turn_id"):
        if data.get(key):
            enriched[key] = data[key]
    session = _gw_sessions().get(sid)
    stored = data.get("stored_session_id") or (session or {}).get("session_key")
    if stored:
        enriched["stored_session_id"] = stored
    # Gateway approvals are dangerous-command gated, so a pattern match means a
    # destructive/irreversible action. Honour an explicit flag if the payload
    # carries one; otherwise infer from the pattern keys.
    explicit = data.get("destructive")
    if isinstance(explicit, bool):
        enriched["destructive"] = explicit
    else:
        enriched["destructive"] = bool(
            data.get("pattern_keys") or data.get("pattern_key")
        )
    title = (
        data.get("approval_title")
        or data.get("target")
        or data.get("command")
        or data.get("title")
    )
    if title:
        enriched["approval_title"] = _push_safe_text(title, "", max_chars=120)
    return enriched


def _push_route_context(sid: str, data: dict) -> dict:
    """Shared APNs route/correlation context for clarify and turn completion."""
    context: dict = {"session_id": sid}
    stored = data.get("stored_session_id") or (
        _gw_sessions().get(sid) or {}
    ).get("session_key")
    if stored:
        context["stored_session_id"] = stored
    for key in ("event_id", "gateway_scope", "turn_id", "request_id", "approval_id"):
        if data.get(key):
            context[key] = data[key]
    return context


def _live_activity_status_phase(data: dict) -> tuple[str, bool]:
    kind = str(data.get("kind") or "status").strip().lower()
    if kind in _LA_BLOCKING_STATUS_KINDS:
        return "waiting", kind in {"approval", "approve"}
    return "thinking", False


def _live_activity_content_state(
    *,
    phase: str,
    tool_name: str | None,
    elapsed_seconds: int,
    needs_approval: bool,
    started_at_epoch_seconds: int | None,
) -> dict:
    """Build the exact ActivityKit state shape shared by every event path."""
    state = {
        "phase": phase,
        "toolName": tool_name,
        "elapsedSeconds": max(0, int(elapsed_seconds or 0)),
        "needsApproval": needs_approval,
    }
    if started_at_epoch_seconds is not None:
        state["startedAtEpochSeconds"] = started_at_epoch_seconds
    return state


def _live_activity_end_content_state(
    elapsed_seconds: int = 0,
    *,
    started_at_epoch_seconds: int | None = None,
) -> dict:
    """Terminal Live Activity content-state shared by every turn-death path."""
    return _live_activity_content_state(
        phase="done",
        tool_name=None,
        elapsed_seconds=elapsed_seconds,
        needs_approval=False,
        started_at_epoch_seconds=started_at_epoch_seconds,
    )


def _unique_live_activity_session_ids(*session_ids: object) -> list[str]:
    ids: list[str] = []
    for raw in session_ids:
        sid = str(raw or "").strip()
        if sid and sid not in ids:
            ids.append(sid)
    return ids


def _send_live_activity_end_frame(session_id: str, *, elapsed_seconds: int = 0) -> bool:
    """Best-effort terminal frame for one registered Live Activity token."""
    if live_activity_token_for(session_id) is None:
        return False
    session = _gw_sessions().get(session_id) or {}
    started_at = session.get("_la_started_at_epoch_seconds")
    if started_at is None and session.get("_push_turn_started") is not None:
        started_at = int(session["_push_turn_started"])
    return notify_live_activity(
        session_id,
        _live_activity_end_content_state(
            elapsed_seconds,
            started_at_epoch_seconds=started_at,
        ),
        end=True,
        priority=_LIVE_ACTIVITY_PRIORITY_IMMEDIATE,
    )


def end_live_activity_sessions(*session_ids: object, elapsed_seconds: int = 0) -> int:
    """Send terminal frames, then drop registry rows, for ended sessions.

    Used by non-happy-path teardown/reconciliation paths where there may never
    be a ``message.complete`` event.  Registry cleanup is retained even if the
    APNs send is a no-op/failure, matching the previous finalize/delete cleanup
    behavior: once the server knows the turn/session is dead, the token must not
    keep receiving live updates.
    """
    ended = 0
    for sid in _unique_live_activity_session_ids(*session_ids):
        had_token = live_activity_token_for(sid) is not None
        if had_token:
            _send_live_activity_end_frame(sid, elapsed_seconds=elapsed_seconds)
            ended += 1
        try:
            unregister_live_activity_token(sid)
        except Exception:
            _log.debug(
                "failed to unregister Live Activity token for %s",
                sid,
                exc_info=True,
            )
    return ended


def _active_live_activity_session_ids() -> set[str]:
    """Session ids that currently map to a live gateway session."""
    active: set[str] = set()
    for sid, session in _gw_sessions().items():
        for value in (
            sid,
            (session or {}).get("_runtime_sid") if isinstance(session, dict) else None,
            (session or {}).get("session_id") if isinstance(session, dict) else None,
            (session or {}).get("session_key") if isinstance(session, dict) else None,
            getattr((session or {}).get("agent"), "session_id", None)
            if isinstance(session, dict)
            else None,
        ):
            text = str(value or "").strip()
            if text:
                active.add(text)
    return active


def sweep_dead_live_activity_tokens(active_session_ids: set[str] | None = None) -> int:
    """End and prune LA tokens whose sessions are not live after startup.

    A gateway restart can strand the JSON registry with ActivityKit tokens from
    turns that died with the old process.  On the next plugin activation, compare
    the registry against the current live session table and send an end frame for
    anything that no longer has a live owner.
    """
    prune_live_activity_tokens()
    active = (
        _active_live_activity_session_ids()
        if active_session_ids is None
        else active_session_ids
    )
    dead = [sid for sid in _load_la_registry().keys() if sid not in active]
    return end_live_activity_sessions(*dead)


def _live_activity_hook(
    event: str,
    sid: str,
    payload: dict | None,
    *,
    event_time: float | None = None,
    turn_started: float | None = None,
) -> None:
    """Drive ActivityKit Live Activity remote updates from gateway events.

    Silent no-op unless push is armed AND the session has a registered Live
    Activity token. Routine tool/progress frames use APNs priority 5 and are
    coalesced by visible semantic state plus the three-second budget floor.
    Start, approval, clarification, blocking status, error, and end transitions
    use priority 10 and bypass routine coalescing. ``content-state`` uses the
    exact HermesTurnAttributes.ContentState Codable field names and carries one
    stable Unix start epoch for the activity lifetime.
    """
    try:
        if not APNsConfig.from_env().is_armed():
            return
        if live_activity_token_for(sid) is None:
            return

        session = _gw_sessions().get(sid)
        # Keep the worker safe for direct callers and lifecycle-hook intake.
        data = enrich_correlated_event(event, sid, payload) or {}
        is_end = event in ("message.complete", "session.interrupt")
        now = event_time or time.time()

        # Elapsed seconds and the stable wire epoch both derive from the turn
        # start stamped on message.start. The integer epoch is cached separately
        # so every frame has byte-identical start-time semantics even as elapsed
        # seconds advance.
        current_started = (session or {}).get("_push_turn_started")
        started = turn_started
        if started is None:
            started = current_started
        if event == "message.start" and started is None:
            started = now
        started_at_epoch_seconds = (session or {}).get(
            "_la_started_at_epoch_seconds"
        )
        if event == "message.start":
            started_at_epoch_seconds = int(started)
            if session is not None:
                session["_la_started_at_epoch_seconds"] = started_at_epoch_seconds
        elif started_at_epoch_seconds is None and started is not None:
            started_at_epoch_seconds = int(started)
            if session is not None:
                session["_la_started_at_epoch_seconds"] = started_at_epoch_seconds
        elif started_at_epoch_seconds is None:
            # A registered activity can outlive incomplete gateway bookkeeping
            # (for example an interrupt before message.start was retained). Give
            # that lifetime one stable epoch rather than changing it per frame.
            started_at_epoch_seconds = int(now)
            if session is not None:
                session["_la_started_at_epoch_seconds"] = started_at_epoch_seconds
        elapsed = int(max(0.0, now - started)) if started else 0
        immediate = is_end

        if event == "message.start":
            if session is not None:
                session.pop("_la_end_sent_turn_started", None)
                session.pop("_la_last_semantic_state", None)
            phase, tool_name, needs_approval = "thinking", None, False
            immediate = True
        elif event == "tool.start":
            phase = "tool"
            tool_name = str(data.get("name")) if data.get("name") else None
            needs_approval = False
        elif event == "tool.complete":
            phase, tool_name, needs_approval = "thinking", None, False
        elif event == "approval.request":
            phase, tool_name, needs_approval = "waiting", None, True
            immediate = True
        elif event == "clarify.request":
            phase, tool_name, needs_approval = "waiting", None, False
            immediate = True
        elif event == "status.update":
            phase, needs_approval = _live_activity_status_phase(data)
            tool_name = None
            if str(data.get("kind") or "").strip().lower() in _LA_BLOCKING_STATUS_KINDS:
                immediate = True
        elif event == "error":
            phase, tool_name, needs_approval = "error", None, False
            immediate = True
        elif is_end:
            if (
                session is not None
                and turn_started is not None
                and current_started is not None
                and current_started != turn_started
            ):
                return
            if session is not None:
                end_key = started if started is not None else "__unknown__"
                if session.get("_la_end_sent_turn_started") == end_key:
                    return
                session["_la_end_sent_turn_started"] = end_key
            phase, tool_name, needs_approval = "done", None, False
        else:
            return

        content_state = _live_activity_content_state(
            phase=phase,
            tool_name=tool_name,
            elapsed_seconds=elapsed,
            needs_approval=needs_approval,
            started_at_epoch_seconds=started_at_epoch_seconds,
        )

        # Routine frames only spend budget when user-visible state changed.
        # elapsedSeconds is deliberately excluded: the stable start epoch lets
        # ActivityKit render elapsed time locally without timer-refresh pushes.
        semantic_state = (phase, tool_name, needs_approval)
        if not immediate and session is not None:
            if session.get("_la_last_semantic_state") == semantic_state:
                return
            last = session.get("_la_last_update", 0.0)
            if (now - last) < _LIVE_ACTIVITY_THROTTLE_S:
                return
        if session is not None:
            session["_la_last_update"] = now
            session["_la_last_semantic_state"] = semantic_state

        notify_live_activity(
            sid,
            content_state,
            end=is_end,
            priority=(
                _LIVE_ACTIVITY_PRIORITY_IMMEDIATE
                if immediate
                else _LIVE_ACTIVITY_PRIORITY_ROUTINE
            ),
        )
    except Exception:
        _log.debug("live activity hook failed", exc_info=True)


def _push_hook(
    event: str,
    sid: str,
    payload: dict | None,
    *,
    turn_started: float | None = None,
) -> None:
    """Queue attention-worthy events for APNs (hermes-mobile plugin).

    This hook performs only cheap in-memory work on the emit path. APNs sends
    and registry reads happen on the background push worker.
    """
    try:
        event_time = time.time()
        session = _gw_sessions().get(sid)
        if event == "message.start":
            if session is not None:
                session["_push_turn_started"] = event_time
        if turn_started is None:
            turn_started = (session or {}).get("_push_turn_started")
        # ABH-204: a dispatched kanban worker's internal turn / tool / status /
        # message.complete events must not enqueue a phone push. Approval
        # requests still enqueue (and push) so the user can act on them. The
        # message.complete branch in _process_push_event keeps its own guard as
        # defense-in-depth. Live Activity is a no-op for workers in practice
        # (no registered activity token), and approvals still flow regardless.
        if _is_kanban_worker() and event != "approval.request":
            return
        if event in _PUSH_ALERT_EVENTS or event in _LIVE_ACTIVITY_EVENTS:
            _enqueue_push_event(
                event,
                sid,
                payload,
                event_time=event_time,
                turn_started=turn_started,
            )
    except Exception:
        _log.debug("push hook failed", exc_info=True)


def _process_push_event(
    event: str,
    sid: str,
    payload: dict | None,
    *,
    event_time: float | None = None,
    turn_started: float | None = None,
) -> None:
    """Run APNs work for a queued gateway event."""
    try:
        # Live Activity remote updates run for every relevant event (and are a
        # no-op when push is unarmed / no LA token is registered).
        if event in _LIVE_ACTIVITY_EVENTS:
            _live_activity_hook(
                event,
                sid,
                payload,
                event_time=event_time,
                turn_started=turn_started,
            )

        if event not in _PUSH_ALERT_EVENTS:
            return

        # Keep the worker safe for direct callers and lifecycle-hook intake.
        data = enrich_correlated_event(event, sid, payload) or {}
        excluded_devices = _foreground_phone_devices(sid, _gw_sessions().get(sid))
        if event == "approval.request":
            title = _push_safe_text(data.get("title"), "Approval required", max_chars=80)
            body = _push_safe_text(
                data.get("description") or data.get("target"),
                "Review this approval in Hermes",
            )
            alert_payload = _push_approval_enrichment(sid, data)
            notify(
                "approval",
                title,
                body,
                alert_payload,
                category="HERMES_APPROVAL",
                collapse_id=alert_payload.get("event_id"),
                excluding_device_ids=excluded_devices,
            )
        elif event == "clarify.request":
            clarify_payload = _push_route_context(sid, data)
            request_id = str(data.get("request_id") or "").strip()
            if request_id:
                clarify_payload.update(
                    {"approval_id": request_id, "response_action": "reply"}
                )
            notify(
                "clarify",
                "Hermes has a question",
                _push_safe_text(data.get("question"), "Input needed"),
                clarify_payload,
                category="HERMES_CLARIFY",
                collapse_id=clarify_payload.get("event_id"),
                excluding_device_ids=excluded_devices,
            )
        elif event == "error":
            if _is_kanban_worker():
                return
            message = str(data.get("message") or "")
            preview = (
                _push_safe_text(message.strip().splitlines()[0], "Turn errored")
                if message.strip()
                else "Turn errored"
            )
            notify(
                "turn_error",
                "Hermes hit an error",
                preview,
                {"session_id": sid},
                category="HERMES_ERROR",
                excluding_device_ids=excluded_devices,
            )
        elif event == "background.complete":
            if _is_kanban_worker():
                return
            text = str(data.get("text") or "")
            preview = (
                _push_safe_text(text.strip().splitlines()[0], "Job finished")
                if text.strip()
                else "Job finished"
            )
            notify(
                "background_done",
                "Background job finished",
                preview,
                {"session_id": sid, "task_id": data.get("task_id")},
                category="HERMES_TURN",
                excluding_device_ids=excluded_devices,
            )
        else:  # message.complete — push unless the user is watching live
            session = _gw_sessions().get(sid)
            # Registry hygiene: clear this turn's start stamp regardless of
            # whether we end up pushing (a foregrounded turn must still drop
            # its stamp). Guarded so we only pop the stamp for this turn.
            started = turn_started
            if started is None:
                started = (session or {}).get("_push_turn_started")
            if session is not None and session.get("_push_turn_started") == started:
                session.pop("_push_turn_started", None)
            # Suppress only the authenticated phone device actively displaying
            # this stored session. A desktop owning the runtime is not a phone
            # foreground signal and must never suppress the phone's completion.
            # ABH-204: a dispatched kanban worker's internal turns must not
            # spam the phone with a turn-complete alert. Approval requests
            # still push (their own branch above); Live Activity is unaffected.
            if _is_kanban_worker():
                return
            text = str(data.get("text") or "")
            preview = (
                _push_safe_text(text.strip().splitlines()[0], "Turn finished")
                if text.strip()
                else "Turn finished"
            )
            # 4h store-and-forward window: a locked/off phone should still get
            # the turn-complete banner when it wakes. Time-sensitive alerts
            # (approval/clarify/error/background) keep expiration=0.
            turn_payload = _push_route_context(sid, data)
            notify(
                "turn_complete",
                "Hermes finished",
                preview,
                turn_payload,
                category="HERMES_TURN",
                expiration=14400,
                collapse_id=turn_payload.get("event_id"),
                excluding_device_ids=excluded_devices,
            )
    except Exception:
        _log.debug("push hook failed", exc_info=True)


def unregister_live_activity_tokens(*session_ids: object) -> None:
    """Best-effort Live Activity registry cleanup for ended sessions.

    Moved verbatim from ``tui_gateway/server.py`` (the lazy push_notify import
    became a direct local call after the move).  ABH-361 extends the cleanup to
    send a terminal ActivityKit frame before pruning, so teardown paths that
    never emit ``message.complete`` do not leave a zombie lock-screen timer.
    """
    end_live_activity_sessions(*session_ids)


_STOCK_PUSH_PLATFORMS = frozenset({"cli", "desktop", "tui"})
_STOCK_TURNS: dict[tuple[str, str], float] = {}


def _stock_turn_key(session_id: object, turn_id: object) -> tuple[str, str]:
    return str(session_id or "").strip(), str(turn_id or "").strip()


def _stock_started(session_id: object, turn_id: object) -> float | None:
    key = _stock_turn_key(session_id, turn_id)
    return _STOCK_TURNS.get(key) if all(key) else None


def _delivery_sid(stored_session_id: str) -> str:
    """Use the live runtime id when ActivityKit has registered one."""
    for runtime_id, session in _gw_sessions().items():
        if not isinstance(session, dict):
            continue
        agent = session.get("agent")
        if stored_session_id in {
            str(session.get("session_key") or ""),
            str(session.get("session_id") or ""),
            str(getattr(agent, "session_id", "") or ""),
        }:
            return str(runtime_id)
    return stored_session_id


def _stock_platform_allowed(platform: object) -> bool:
    return str(platform or "").strip().lower() in _STOCK_PUSH_PLATFORMS


def _invalidate_stock_event(event: str, sid: str, payload: dict | None) -> None:
    try:
        from .manifest_invalidation import handle_gateway_event as invalidate_event

        invalidate_event(event, sid, payload)
    except Exception:
        _log.warning("manifest invalidation journal failed", exc_info=True)


def _emit_stock_event(
    event: str,
    stored_session_id: str,
    payload: dict | None = None,
    *,
    turn_started: float | None = None,
) -> None:
    """Feed one upstream lifecycle callback into the existing push pipeline."""
    data = dict(payload or {})
    data.setdefault("stored_session_id", stored_session_id)
    sid = _delivery_sid(stored_session_id)
    _invalidate_stock_event(event, sid, data)
    _push_hook(event, sid, data, turn_started=turn_started)


def handle_turn_start(
    *,
    session_id: str = "",
    task_id: str = "",
    turn_id: str = "",
    platform: str = "",
    **_kwargs,
) -> None:
    """Translate stock ``pre_llm_call`` into one turn-start event."""
    stored = str(session_id or task_id or "").strip()
    key = _stock_turn_key(stored, turn_id)
    if not all(key) or not _stock_platform_allowed(platform):
        return
    started = time.time()
    if len(_STOCK_TURNS) >= 512:
        _STOCK_TURNS.pop(next(iter(_STOCK_TURNS)))
    _STOCK_TURNS[key] = started
    _emit_stock_event(
        "message.start",
        stored,
        {"turn_id": str(turn_id), "platform": str(platform)},
        turn_started=started,
    )


def handle_turn_reply(
    *,
    session_id: str = "",
    task_id: str = "",
    turn_id: str = "",
    assistant_response: str = "",
    platform: str = "",
    **_kwargs,
) -> None:
    """Translate stock ``post_llm_call`` into one reply-ready event."""
    stored = str(session_id or task_id or "").strip()
    if not stored or not _stock_platform_allowed(platform):
        return
    _emit_stock_event(
        "message.complete",
        stored,
        {
            "text": str(assistant_response or ""),
            "status": "complete",
            "turn_id": str(turn_id or ""),
            "platform": str(platform),
        },
        turn_started=_stock_started(stored, turn_id),
    )


def handle_api_request_error(
    *,
    session_id: str = "",
    task_id: str = "",
    turn_id: str = "",
    error: object = None,
    reason: str | None = None,
    retryable: bool | None = None,
    **_kwargs,
) -> None:
    """Push only a provider error that stock classifies as non-retryable."""
    stored = str(session_id or task_id or "").strip()
    started = _stock_started(stored, turn_id)
    if started is None or retryable is not False:
        return
    if isinstance(error, dict):
        message = error.get("message") or error.get("type")
    else:
        message = error
    _emit_stock_event(
        "error",
        stored,
        {
            "message": _push_safe_text(
                message or reason, "Hermes could not finish this turn"
            ),
            "turn_id": str(turn_id or ""),
        },
        turn_started=started,
    )


def handle_turn_end(
    *,
    session_id: str = "",
    task_id: str = "",
    turn_id: str = "",
    interrupted: bool = False,
    **_kwargs,
) -> None:
    """End Live Activity state for interrupted turns and release turn tracking."""
    stored = str(session_id or task_id or "").strip()
    key = _stock_turn_key(stored, turn_id)
    started = _STOCK_TURNS.pop(key, None)
    if not stored or started is None or not interrupted:
        return
    _emit_stock_event(
        "session.interrupt",
        stored,
        {"turn_id": str(turn_id or ""), "status": "interrupted"},
        turn_started=started,
    )


def handle_pre_tool_call(
    *,
    tool_name: str = "",
    args: dict | None = None,
    session_id: str = "",
    task_id: str = "",
    turn_id: str = "",
    tool_call_id: str = "",
    **_kwargs,
) -> None:
    """Drive tool Live Activity state and clarification attention from stock hooks."""
    stored = str(session_id or task_id or "").strip()
    started = _stock_started(stored, turn_id)
    if started is None:
        return
    safe_args = args if isinstance(args, dict) else {}
    if tool_name == "clarify":
        choices = safe_args.get("choices")
        _emit_stock_event(
            "clarify.request",
            stored,
            {
                "question": str(safe_args.get("question") or "Input needed"),
                "choices": (
                    [str(choice) for choice in choices[:20]]
                    if isinstance(choices, list)
                    else []
                ),
                "tool_call_id": str(tool_call_id or ""),
                "turn_id": str(turn_id or ""),
            },
            turn_started=started,
        )
        return
    _emit_stock_event(
        "tool.start",
        stored,
        {"name": str(tool_name or "tool"), "turn_id": str(turn_id or "")},
        turn_started=started,
    )


def handle_post_tool_call(
    *,
    tool_name: str = "",
    session_id: str = "",
    task_id: str = "",
    turn_id: str = "",
    **_kwargs,
) -> None:
    """Close stock tool activity without copying tool results into push payloads."""
    stored = str(session_id or task_id or "").strip()
    started = _stock_started(stored, turn_id)
    if started is None:
        return
    if tool_name == "clarify":
        _invalidate_stock_event(
            "clarify.resolved",
            _delivery_sid(stored),
            {"stored_session_id": stored, "turn_id": str(turn_id or "")},
        )
    _emit_stock_event(
        "tool.complete",
        stored,
        {"name": str(tool_name or "tool"), "turn_id": str(turn_id or "")},
        turn_started=started,
    )


def handle_gateway_event(event: str, sid: str, payload: dict | None = None) -> None:
    """Compatibility intake for the authenticated external notification route."""
    _invalidate_stock_event(event, sid, payload)
    if event == "session.finalize":
        data = payload or {}
        unregister_live_activity_tokens(
            sid, data.get("session_id"), data.get("session_key")
        )
        return
    if event == "session.deleted":
        end_live_activity_sessions(sid)
        return
    # Approval alerts originate at the stock pre_approval_request hook below.
    # The emitted frame still reaches live clients and manifest invalidation,
    # but must not enqueue a second APNs alert.
    if event == "approval.request":
        return
    _push_hook(event, sid, payload)


def handle_approval_request(
    *,
    session_key: str = "",
    surface: str = "",
    command: str = "",
    description: str = "",
    turn_id: str = "",
    tool_call_id: str = "",
    **_kwargs,
) -> None:
    """Turn the stock approval hook into one actionable mobile push."""
    if surface == "smart" or not session_key:
        return
    started = _stock_started(session_key, turn_id)
    if surface != "cli" and started is None:
        return
    sid = next(
        (
            runtime_id
            for runtime_id, session in _gw_sessions().items()
            if isinstance(session, dict) and session.get("session_key") == session_key
        ),
        session_key,
    )
    request_id = ""
    choices: list[str] = []
    try:
        from tools.approval import pending_approval_snapshot

        pending = [
            item
            for item in pending_approval_snapshot()
            if item.get("stored_session_id") == session_key
        ]
        if pending:
            latest = pending[-1]
            request_id = str(latest.get("request_id") or "")
            detail = latest.get("detail") or {}
            choices = list(detail.get("choices") or [])
            safe_description = str(detail.get("description") or "Approval required")
        else:
            safe_description = "Approval required"
    except Exception:
        _log.debug("approval snapshot lookup failed", exc_info=True)
        safe_description = "Approval required"
    payload = {
        "title": "Approval required",
        "description": safe_description,
        "stored_session_id": session_key,
        "request_id": request_id,
        "approval_id": request_id,
        "event_id": request_id,
        "choices": choices,
        "turn_id": str(turn_id or ""),
        "tool_call_id": str(tool_call_id or ""),
    }
    _invalidate_stock_event("approval.request", sid, payload)
    _push_hook(
        "approval.request",
        sid,
        payload,
        turn_started=started,
    )


def handle_approval_response(
    *,
    session_key: str = "",
    surface: str = "",
    turn_id: str = "",
    **_kwargs,
) -> None:
    """Clear stock approval attention after approve, deny, or timeout."""
    if surface == "smart" or not session_key:
        return
    started = _stock_started(session_key, turn_id)
    if surface != "cli" and started is None:
        return
    _invalidate_stock_event(
        "approval.resolved",
        _delivery_sid(session_key),
        {"stored_session_id": session_key, "turn_id": str(turn_id or "")},
    )
    if started is not None:
        _emit_stock_event(
            "status.update",
            session_key,
            {"kind": "thinking", "turn_id": str(turn_id or "")},
            turn_started=started,
        )


def handle_session_finalize(
    session_id: str | None = None,
    **_kwargs,
) -> None:
    """End Live Activities for the durable id of a closing stock session.

    Stock Hermes exposes ``on_session_finalize`` with the stored conversation
    id. The phone owns runtime-keyed ActivityKit teardown; this hook is the
    durable-id cleanup fallback.
    """
    end_live_activity_sessions(session_id)


def activate(ctx=None) -> None:
    """Wire notification intake exclusively through stock Hermes v0.19 hooks."""
    if ctx is None:
        return
    ctx.register_hook("pre_llm_call", handle_turn_start)
    ctx.register_hook("post_llm_call", handle_turn_reply)
    ctx.register_hook("on_session_end", handle_turn_end)
    ctx.register_hook("pre_tool_call", handle_pre_tool_call)
    ctx.register_hook("post_tool_call", handle_post_tool_call)
    ctx.register_hook("api_request_error", handle_api_request_error)
    ctx.register_hook("pre_approval_request", handle_approval_request)
    ctx.register_hook("post_approval_response", handle_approval_response)
    ctx.register_hook("on_session_finalize", handle_session_finalize)
    sweep_dead_live_activity_tokens()
