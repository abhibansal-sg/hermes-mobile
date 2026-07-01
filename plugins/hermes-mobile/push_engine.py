"""
hermes-mobile plugin — APNs push engine (dormant by default).

Moved verbatim from ``hermes_cli/push_notify.py`` (ABH-88 de-patch, W1) plus
the gateway event-intake block moved from ``tui_gateway/server.py``. The
``/push/*`` REST routes live in this plugin's ``dashboard/api.py`` (mounted at
``/api/plugins/hermes-mobile/push/...``); event intake rides the gateway's S2
emit-observer seam (see CONTRACT-DEPATCH.md), wired by :func:`activate`.

Sends Apple Push Notification service (APNs) alert pushes to iOS devices that
have registered their device token with the gateway. The whole subsystem is a
silent no-op unless **both**:

  * ``HERMES_PUSH_ENABLED`` is truthy, and
  * the APNs auth key file (``HERMES_APNS_KEY_FILE``) exists on disk.

That keeps the gateway shippable without any APNs credentials: hooks can call
:func:`notify` unconditionally and nothing happens until an operator opts in.

Configuration (all via environment):

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

Device tokens live in a JSON registry at ``<HERMES_HOME>/push_tokens.json``
(``~/.hermes/push_tokens.json`` by default), populated by the plugin's
``POST``/``DELETE .../push/register`` routes. Invalid tokens are pruned
automatically when APNs replies ``410 Unregistered``.

The pure builders (:func:`build_provider_jwt`, :func:`build_push_headers`,
:func:`build_alert_payload`) take no I/O and are unit-tested directly.

Optional deps (PyJWT + cryptography) are imported lazily; importing this module
never fails. If they are absent the sender degrades to a no-op and the JWT
builder raises :class:`PushDependencyError` with the pip install hint.
"""

from __future__ import annotations

import atexit
import copy
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
# Pure builders — no I/O, unit-tested directly.
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


def build_push_headers(
    *,
    provider_jwt: str,
    topic: str,
    push_type: str = "alert",
    priority: int = 10,
    collapse_id: Optional[str] = None,
    expiration: int = 0,
) -> Dict[str, str]:
    """Build the APNs HTTP/2 request headers for an alert push.

    ``expiration`` of 0 means "deliver once, do not store" — appropriate for
    time-sensitive turn / approval alerts. ``collapse_id`` (<=64 bytes) lets
    APNs coalesce updates for the same logical event.
    """
    headers: Dict[str, str] = {
        "authorization": f"bearer {provider_jwt}",
        "apns-topic": topic,
        "apns-push-type": push_type,
        "apns-priority": str(priority),
        "apns-expiration": str(expiration),
    }
    if collapse_id:
        # APNs caps the collapse id at 64 bytes.
        headers["apns-collapse-id"] = collapse_id[:64]
    return headers


def build_alert_payload(
    *,
    title: str,
    body: str,
    event_type: str,
    payload: Optional[Dict[str, Any]] = None,
    sound: str = "default",
    badge: Optional[int] = None,
    category: Optional[str] = None,
) -> Dict[str, Any]:
    """Shape the APNs JSON payload for an alert push.

    Produces the standard ``aps`` envelope plus a flat ``hermes`` block of
    custom keys (event type + caller-supplied payload) the iOS app reads on
    tap. ``payload`` keys never overwrite the reserved ``aps``/``hermes``
    envelope; the whole custom block is namespaced under ``hermes``.

    ``category`` (when set) becomes ``aps.category`` so iOS can attach the
    matching ``UNNotificationCategory`` action set (e.g. Approve/Deny on
    ``HERMES_APPROVAL``). Omitted when None to keep legacy alerts unchanged.
    """
    aps: Dict[str, Any] = {
        "alert": {"title": title, "body": body},
        "sound": sound,
    }
    if badge is not None:
        aps["badge"] = badge
    if category:
        aps["category"] = category

    custom: Dict[str, Any] = {"event_type": event_type}
    if payload:
        custom.update(payload)

    return {"aps": aps, "hermes": custom}


# ---------------------------------------------------------------------------
# Live Activity (ActivityKit) remote-update payload + headers.
#
# A Live Activity push targets the activity's own push token (NOT the app's
# device token) and uses a dedicated apns-push-type/topic. The content-state
# keys MUST match HermesTurnAttributes.ContentState exactly (Swift Codable):
#   phase: String, toolName: String?, elapsedSeconds: Int, needsApproval: Bool
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
# Device token registry — JSON file at <HERMES_HOME>/push_tokens.json.
# A module-level lock serialises read-modify-write so concurrent register /
# notify (token pruning) calls don't clobber the file.
# ---------------------------------------------------------------------------

_registry_lock = threading.Lock()

# iOS APNs device tokens are 64 hex chars (32 bytes). We validate loosely
# (hex, even length, sane size) so future token lengths don't hard-break.
_MIN_TOKEN_LEN = 32
_MAX_TOKEN_LEN = 200


def _registry_path() -> Path:
    """Resolve the token registry path, honouring HERMES_HOME overrides.

    Falls back to ``~/.hermes/push_tokens.json`` if the hermes config package
    can't be imported (keeps this module importable in isolation / tests).
    """
    try:
        from hermes_cli.config import get_hermes_home

        return get_hermes_home() / "push_tokens.json"
    except Exception:  # pragma: no cover - defensive fallback
        return Path(os.path.expanduser("~/.hermes")) / "push_tokens.json"


def _normalize_token(token: str) -> Optional[str]:
    """Return a lowercased hex device token, or None if it's malformed."""
    if not isinstance(token, str):
        return None
    t = token.strip().lower().replace(" ", "")
    if not (_MIN_TOKEN_LEN <= len(t) <= _MAX_TOKEN_LEN):
        return None
    try:
        int(t, 16)
    except ValueError:
        return None
    return t


def _load_registry() -> List[Dict[str, Any]]:
    """Load the registry as a list of ``{token, platform, registered_at}``."""
    path = _registry_path()
    try:
        raw = path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError):
        return []
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        _log.warning("push_tokens.json is corrupt; treating as empty")
        return []
    if not isinstance(data, list):
        return []
    out: List[Dict[str, Any]] = []
    for entry in data:
        if isinstance(entry, dict) and isinstance(entry.get("token"), str):
            out.append(entry)
    return out


def _save_registry(entries: List[Dict[str, Any]]) -> None:
    path = _registry_path()
    try:
        # Registry holds APNs device tokens. Create the temp file at 0600 before
        # writing bytes, then atomically replace, so a permissive umask cannot
        # briefly expose token material before a post-write chmod.
        atomic_json_write(path, entries, indent=2, mode=0o600)
    except OSError as exc:
        _log.warning("Could not persist push_tokens.json: %s", exc)


def _default_env() -> str:
    """Server-level fallback APNs environment for tokens registered by older
    clients that don't report one."""
    return "sandbox" if _is_truthy(os.environ.get("HERMES_APNS_USE_SANDBOX")) else "production"


# The per-event preference vocabulary. A registry entry may opt into a subset;
# ``None``/absent means "all events" so legacy entries (registered before prefs
# existed) keep receiving every push.
PUSH_EVENT_KINDS = ("approval", "clarify", "turn_complete")


def _normalize_events(events: Optional[List[str]]) -> Optional[List[str]]:
    """Validate a per-event preference list.

    Returns a de-duplicated, order-preserving subset of :data:`PUSH_EVENT_KINDS`
    or ``None`` (meaning "all events" — the legacy default). An empty list is
    preserved as an explicit "no events" opt-out (distinct from ``None``).
    """
    if events is None:
        return None
    if not isinstance(events, (list, tuple)):
        return None
    seen: List[str] = []
    for ev in events:
        if isinstance(ev, str) and ev in PUSH_EVENT_KINDS and ev not in seen:
            seen.append(ev)
    return seen


def _entry_wants_event(entry: Dict[str, Any], event_kind: str) -> bool:
    """Does this registry entry want a push for ``event_kind``?

    Absent/``None`` ``events`` → all events (legacy entries). An explicit list
    filters; an explicit empty list means "no events".
    """
    prefs = entry.get("events")
    if prefs is None:
        return True
    if not isinstance(prefs, list):
        return True  # malformed → fail open (don't silently drop a device)
    return event_kind in prefs


def register_token(
    token: str,
    platform: str = "ios",
    env: str = "",
    events: Optional[List[str]] = None,
) -> bool:
    """Add (or refresh) a device token in the registry. Returns False if the
    token is malformed.

    ``env`` is the APNs environment the *client build* belongs to
    ("sandbox" for Xcode/dev-signed installs, "production" for
    TestFlight/App Store). Tokens are routed to the matching APNs host per
    entry — a single gateway can serve both build flavors simultaneously.

    ``events`` is the per-event opt-in list (subset of
    :data:`PUSH_EVENT_KINDS`); ``None`` means "all events" (legacy default).
    On re-register the stored prefs are replaced with the new value so the app
    can change its Notification toggles by re-POSTing.
    """
    normalized = _normalize_token(token)
    if normalized is None:
        return False
    environment = env if env in ("sandbox", "production") else _default_env()
    normalized_events = _normalize_events(events)
    with _registry_lock:
        entries = _load_registry()
        now = time.time()
        for entry in entries:
            if _normalize_token(entry.get("token", "")) == normalized:
                entry["platform"] = platform
                entry["env"] = environment
                entry["registered_at"] = now
                if normalized_events is None:
                    entry.pop("events", None)
                else:
                    entry["events"] = normalized_events
                _save_registry(entries)
                return True
        new_entry: Dict[str, Any] = {
            "token": normalized, "platform": platform, "env": environment,
            "registered_at": now,
        }
        if normalized_events is not None:
            new_entry["events"] = normalized_events
        entries.append(new_entry)
        _save_registry(entries)
    return True


def unregister_token(token: str) -> bool:
    """Remove a device token. Returns True if a token was removed."""
    normalized = _normalize_token(token)
    if normalized is None:
        return False
    with _registry_lock:
        entries = _load_registry()
        kept = [
            e for e in entries
            if _normalize_token(e.get("token", "")) != normalized
        ]
        if len(kept) == len(entries):
            return False
        _save_registry(kept)
    return True


def registered_tokens() -> List[str]:
    """All currently registered (normalized) device tokens."""
    out: List[str] = []
    for entry in _load_registry():
        n = _normalize_token(entry.get("token", ""))
        if n:
            out.append(n)
    return out


def registered_tokens_by_env() -> Dict[str, List[str]]:
    """Registered tokens grouped by APNs environment ("sandbox"/"production").

    Entries persisted before env tracking existed inherit the server-level
    default so older registries keep working unchanged.
    """
    fallback = _default_env()
    grouped: Dict[str, List[str]] = {}
    for entry in _load_registry():
        n = _normalize_token(entry.get("token", ""))
        if not n:
            continue
        env = entry.get("env")
        if env not in ("sandbox", "production"):
            env = fallback
        grouped.setdefault(env, []).append(n)
    return grouped


def recipients_for_event(event_kind: str) -> Dict[str, List[str]]:
    """Tokens grouped by APNs env, filtered to those wanting ``event_kind``.

    Mirrors :func:`registered_tokens_by_env` but drops entries whose per-event
    prefs exclude this kind. Entries with no prefs (legacy) receive everything.
    Unknown ``event_kind`` values fall open to all entries.
    """
    fallback = _default_env()
    grouped: Dict[str, List[str]] = {}
    known = event_kind in PUSH_EVENT_KINDS
    for entry in _load_registry():
        n = _normalize_token(entry.get("token", ""))
        if not n:
            continue
        if known and not _entry_wants_event(entry, event_kind):
            continue
        env = entry.get("env")
        if env not in ("sandbox", "production"):
            env = fallback
        grouped.setdefault(env, []).append(n)
    return grouped


def _drop_tokens(tokens: List[str]) -> None:
    """Prune the given tokens from the registry (called on 410 Unregistered)."""
    drop = {t for t in (_normalize_token(t) for t in tokens) if t}
    if not drop:
        return
    with _registry_lock:
        entries = _load_registry()
        kept = [
            e for e in entries
            if _normalize_token(e.get("token", "")) not in drop
        ]
        if len(kept) != len(entries):
            _save_registry(kept)


# ---------------------------------------------------------------------------
# Live Activity token registry — JSON file at
# <HERMES_HOME>/live_activity_tokens.json, keyed by session_id.
#
# Unlike the alert registry (a flat list of device tokens), Live Activity
# pushes target the *activity's* own push token, which rotates and is unique
# per in-flight activity. We therefore key by session_id and UPSERT on
# rotation. Pruned on 410 Unregistered like the alert registry.
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
        # Registry holds ActivityKit push tokens; same atomic 0600 posture as
        # the alert registry.
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
    session_id: str, token: str, env: str = ""
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
        entries[session_id] = {
            "token": normalized,
            "env": environment,
            "registered_at": time.time(),
        }
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


def _drop_la_token(session_id: str) -> None:
    """Prune a session's LA token (called on 410 Unregistered)."""
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


def notify(
    event_type: str,
    title: str,
    body: str,
    payload: Optional[Dict[str, Any]] = None,
    *,
    category: Optional[str] = None,
) -> int:
    """Send an alert push to every registered device token.

    Silent no-op (returns 0) unless push is enabled AND the APNs key file
    exists. Tokens that APNs rejects with ``410 Unregistered`` are pruned from
    the registry. Returns the count of pushes accepted (HTTP 200).

    ``event_type`` is also used as the per-event preference key (one of
    :data:`PUSH_EVENT_KINDS` — ``approval``/``clarify``/``turn_complete``):
    only tokens that opted into this kind (or have no prefs) receive the push.
    ``category`` (e.g. ``HERMES_APPROVAL``) becomes ``aps.category`` for the
    iOS action set.

    Never raises: transport / credential errors are logged and swallowed so a
    push failure can never break the calling gateway hook.
    """
    if os.environ.get("HERMES_MOBILE_RELAY_URL"):
        try:
            from . import relay_client

            relay_payload = payload if isinstance(payload, dict) else {}
            relay_client.send_event_background(
                kind=relay_client.map_push_kind(event_type),
                session_id=relay_payload.get("session_id"),
                title=title,
                body=body,
                source=relay_payload.get("source"),
            )
            return 1
        except Exception:
            _log.debug("relay push notify failed", exc_info=True)
            return 0

    config = APNsConfig.from_env()
    if not config.is_armed():
        _log.debug("push notify: not armed (enabled=%s) — no-op", config.enabled)
        return 0

    # Filter recipients by per-event preference before doing any work.
    recipients = recipients_for_event(event_type)
    if not any(recipients.values()):
        return 0

    try:
        import httpx
    except ImportError:
        _log.warning("push notify: httpx unavailable — cannot send (%s)", PIP_INSTALL_HINT)
        return 0

    try:
        provider_jwt = _get_provider_jwt(config)
    except PushDependencyError:
        _log.warning("push notify: %s", PIP_INSTALL_HINT)
        return 0
    except OSError as exc:
        _log.warning("push notify: cannot read APNs key file: %s", exc)
        return 0

    headers = build_push_headers(provider_jwt=provider_jwt, topic=config.topic)
    body_bytes = json.dumps(
        build_alert_payload(
            title=title, body=body, event_type=event_type, payload=payload,
            category=category,
        )
    ).encode("utf-8")

    # Route each token to its own APNs environment: dev-signed builds carry
    # sandbox tokens, TestFlight/App Store builds carry production tokens, and
    # one gateway commonly serves both at once.
    env_hosts = {"sandbox": _APNS_HOST_SANDBOX, "production": _APNS_HOST_PROD}
    accepted = 0
    stale: List[str] = []
    for env, env_tokens in recipients.items():
        if not env_tokens:
            continue
        base_url = f"https://{env_hosts.get(env, config.host)}:{_APNS_PORT}"
        try:
            with httpx.Client(http2=True, base_url=base_url, timeout=10.0) as conn:
                for device_token in env_tokens:
                    try:
                        status, text = _send_one(
                            conn,
                            device_token=device_token,
                            headers=headers,
                            body=body_bytes,
                        )
                    except Exception as exc:  # network hiccup on a single token
                        _log.warning("push notify: send failed for one token: %s", exc)
                        continue
                    if status == 200:
                        accepted += 1
                    elif status == 410:
                        stale.append(device_token)
                    else:
                        _log.info("push notify: APNs %s for token …%s: %s",
                                  status, device_token[-6:], text[:200])
        except Exception as exc:  # pragma: no cover - connection-level failure
            _log.warning("push notify: APNs %s connection failed: %s", env, exc)

    if stale:
        _drop_tokens(stale)
        _log.info("push notify: pruned %d unregistered token(s)", len(stale))

    return accepted


def notify_live_activity(
    session_id: str,
    content_state: Dict[str, Any],
    *,
    end: bool = False,
) -> bool:
    """Send a Live Activity remote update (or end) for ``session_id``.

    Targets the activity's push token registered for this session. Silent
    no-op (returns False) unless push is armed AND a token is registered. The
    token is pruned only on APNs ``410 Unregistered``, matching alert-token
    pruning semantics. Returns True iff APNs accepted the push (HTTP 200).

    ``content_state`` MUST use the ``HermesTurnAttributes.ContentState`` Codable
    field names (``phase``, ``toolName``, ``elapsedSeconds``, ``needsApproval``).

    Never raises: errors are logged and swallowed so a failed LA push can never
    break the calling gateway hook.
    """
    if os.environ.get("HERMES_MOBILE_RELAY_URL"):
        try:
            from . import relay_client

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
        provider_jwt=provider_jwt, topic=config.topic
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
    if status == 410:
        _drop_la_token(session_id)
        _log.info("live activity: pruned dead token for session %s", session_id)
        return False
    _log.info("live activity: APNs %s for session %s: %s",
              status, session_id, text[:200])
    return False




# ===========================================================================
# Gateway event intake — moved verbatim from ``tui_gateway/server.py``
# (ABH-88 de-patch, W1). The gateway's ``_emit`` / finalize / interrupt paths
# notify the S2 emit-observer seam; :func:`handle_gateway_event` is the
# observer this plugin registers there (see :func:`activate`).
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


# Minimum seconds between Live Activity remote updates for one session. The
# final/end update is always sent (it bypasses the throttle) so the activity
# never gets stuck on a stale frame.
_LIVE_ACTIVITY_THROTTLE_S = 3.0
_PUSH_QUEUE_MAX = 512
_PUSH_ALERT_EVENTS = frozenset(
    {"approval.request", "clarify.request", "message.complete"}
)
_LIVE_ACTIVITY_EVENTS = frozenset(
    {
        "message.start",
        "tool.start",
        "tool.complete",
        "approval.request",
        "status.update",
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
    session = _gw_sessions().get(sid)
    stored = (session or {}).get("session_key")
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


def _live_activity_status_phase(data: dict) -> tuple[str, bool]:
    kind = str(data.get("kind") or "status").strip().lower()
    if kind in _LA_BLOCKING_STATUS_KINDS:
        return "waiting", kind in {"approval", "approve"}
    return "thinking", False


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
    Activity token. Updates on tool.start / tool.complete / status.update /
    message.start; ends on message.complete / interrupt. Throttled to one
    update per :data:`_LIVE_ACTIVITY_THROTTLE_S` per session; the end frame is
    always sent. ``content-state`` uses the exact HermesTurnAttributes
    .ContentState Codable field names (phase/toolName/elapsedSeconds/
    needsApproval).
    """
    try:
        if not APNsConfig.from_env().is_armed():
            return
        if live_activity_token_for(sid) is None:
            return

        session = _gw_sessions().get(sid)
        data = payload or {}
        is_end = event in ("message.complete", "session.interrupt")
        now = event_time or time.time()

        # Elapsed seconds from the turn start stamped on message.start.
        current_started = (session or {}).get("_push_turn_started")
        started = turn_started
        if started is None:
            started = current_started
        elapsed = int(max(0.0, now - started)) if started else 0
        bypass_throttle = is_end

        if event == "message.start":
            if session is not None:
                session.pop("_la_end_sent_turn_started", None)
            phase, tool_name, needs_approval = "thinking", None, False
        elif event == "tool.start":
            phase = "tool"
            tool_name = str(data.get("name")) if data.get("name") else None
            needs_approval = False
        elif event == "tool.complete":
            phase, tool_name, needs_approval = "thinking", None, False
        elif event == "approval.request":
            phase, tool_name, needs_approval = "waiting", None, True
            bypass_throttle = True
        elif event == "status.update":
            phase, needs_approval = _live_activity_status_phase(data)
            tool_name = None
            if str(data.get("kind") or "").strip().lower() in _LA_BLOCKING_STATUS_KINDS:
                bypass_throttle = True
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

        content_state = {
            "phase": phase,
            "toolName": tool_name,
            "elapsedSeconds": elapsed,
            "needsApproval": needs_approval,
        }

        # Throttle non-final updates to >=3s/session; the end frame always goes.
        if not is_end and session is not None:
            last = session.get("_la_last_update", 0.0)
            if not bypass_throttle and (now - last) < _LIVE_ACTIVITY_THROTTLE_S:
                return
            session["_la_last_update"] = now

        notify_live_activity(sid, content_state, end=is_end)
    except Exception:
        _log.debug("live activity hook failed", exc_info=True)


def _push_hook(event: str, sid: str, payload: dict | None) -> None:
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
        turn_started = (session or {}).get("_push_turn_started")
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

        data = payload or {}
        if event == "approval.request":
            title = _push_safe_text(data.get("title"), "Approval required", max_chars=80)
            body = _push_safe_text(
                data.get("description") or data.get("target"),
                "Review this approval in Hermes",
            )
            notify(
                "approval",
                title,
                body,
                _push_approval_enrichment(sid, data),
                category="HERMES_APPROVAL",
            )
        elif event == "clarify.request":
            notify(
                "clarify",
                "Hermes has a question",
                _push_safe_text(data.get("question"), "Input needed"),
                {"session_id": sid},
                category="HERMES_CLARIFY",
            )
        else:  # message.complete — only for long turns
            session = _gw_sessions().get(sid)
            started = turn_started
            if started is None:
                started = (session or {}).get("_push_turn_started")
            now = event_time or time.time()
            if started is None or (now - started) < 30:
                return
            if session is not None and session.get("_push_turn_started") == started:
                session.pop("_push_turn_started", None)
            text = str(data.get("text") or "")
            preview = (
                _push_safe_text(text.strip().splitlines()[0], "Turn finished")
                if text.strip()
                else "Turn finished"
            )
            notify(
                "turn_complete",
                "Hermes finished",
                preview,
                {"session_id": sid},
                category="HERMES_TURN",
            )
    except Exception:
        _log.debug("push hook failed", exc_info=True)


def unregister_live_activity_tokens(*session_ids: object) -> None:
    """Best-effort Live Activity registry cleanup for ended sessions.

    Moved verbatim from ``tui_gateway/server.py`` (the lazy push_notify import
    became a direct local call after the move).
    """
    ids: list[str] = []
    for raw in session_ids:
        sid = str(raw or "").strip()
        if sid and sid not in ids:
            ids.append(sid)
    if not ids:
        return
    for sid in ids:
        try:
            unregister_live_activity_token(sid)
        except Exception:
            _log.debug(
                "failed to unregister Live Activity token for %s",
                sid,
                exc_info=True,
            )


def handle_gateway_event(event: str, sid: str, payload: dict | None = None) -> None:
    """S2 emit-observer entry point (see CONTRACT-DEPATCH.md seam S2).

    The gateway notifies observers for every emitted event plus three
    synthetic boundary events that never ride ``_emit``:

    * ``session.finalize`` — sid is the runtime sid; payload carries
      ``session_id`` / ``session_key`` (Live Activity cleanup wants all three).
    * ``session.deleted`` — sid is the STORED session id being deleted.
    * ``session.interrupt`` — mirrors the old explicit ``_push_hook`` call in
      the ``session.interrupt`` RPC handler (ends any in-flight Live Activity).
    """
    if event == "session.finalize":
        data = payload or {}
        unregister_live_activity_tokens(
            sid, data.get("session_id"), data.get("session_key")
        )
        return
    if event == "session.deleted":
        unregister_live_activity_tokens(sid)
        return
    _push_hook(event, sid, payload)


def activate() -> None:
    """Wire the push engine into the gateway's S2 emit-observer seam."""
    from tui_gateway import server as _server

    if handle_gateway_event not in _server._EMIT_OBSERVERS:
        _server._EMIT_OBSERVERS.append(handle_gateway_event)
