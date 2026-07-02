"""Per-device pairing-token registry (hermes-mobile W3a security hardening).

W3a issues a DISTINCT, revocable token per paired device so the single shared
bearer secret (``_SESSION_TOKEN`` / ``~/.hermes/dashboard.token``) stops being
the only auth principal. This module owns the on-disk registry
(``<HERMES_HOME>/device_tokens.json``), the timing-safe match path used by both
the REST and WS auth gates, and the in-process live-WS-socket index used to cut
a revoked device's open sockets immediately.

MIGRATION SAFETY (the overriding W3a constraint): nothing here touches or can
reject the legacy shared token. A device token is a PEER credential, added as an
OR-branch AFTER the shared-token check in the auth gates. ``match`` returning
None simply means "not a device token" — the caller falls through to whatever it
did before.

Security posture (mirrors the LA registry + ws_tickets):
- The token itself (``secrets.token_urlsafe(32)``) is returned to the client
  EXACTLY ONCE at issue time and NEVER stored. The registry persists only
  ``sha256(token)`` (``token_hash``) plus an 8-char ``token_prefix`` for the
  audit log / UI hint. Auth hashes the presented token and ``hmac.compare_digest``
  s it against ``token_hash`` (timing-safe; no recoverable secret on disk).
- The registry file is written through the shared atomic JSON writer with
  ``mode=0o600`` so the temp file is owner-only before any credential metadata is
  written.
- A token is NEVER logged in full: any log/error line truncates to an 8-char
  prefix + "…" (mirroring ``consume_ticket``'s truncation).
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import threading
import time
from collections import OrderedDict
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

from utils import atomic_json_write

_log = logging.getLogger(__name__)

# Serialise every read-modify-write of the on-disk registry (mirror
# ``_la_registry_lock``). issue/revoke/match-last_seen all wrap load+mutate+save
# under this lock.
_registry_lock = threading.Lock()

# In-process map {device_id: set[WebSocket]} of LIVE sockets attributed to a
# device (populated when a WS auth resolves to a device token). Lets revoke cut
# a device's open sockets immediately. The shared-token sockets are NOT indexed
# here — revoking a device must never cut the shared-token live session. Guarded
# by its own lock so WS register/deregister never blocks on a registry write.
_ws_index_lock = threading.Lock()
_ws_device_sockets: Dict[str, Set[Any]] = {}

# Runtime-session attribution for mobile WS turns. A token-authenticated WS is
# first indexed in ``_ws_device_sockets`` by the auth seam. Separately, the TUI
# gateway session table tells us which transport serves runtime session S. This
# plugin-owned map composes the two signals without relying on core-owned
# ``ws.state.device``: {runtime_session_id: (device_id, ws, monotonic_seen_at)}.
# If either side is missing or ambiguous, lookups fail closed. The index is
# deliberately bounded + TTL-pruned because core session close/delete/idle-reap
# lifecycle events are not plugin-owned signals.
_session_index_lock = threading.Lock()
_session_device_sockets: "OrderedDict[str, tuple[str, Any, float]]" = OrderedDict()

# In-process deny-set of REVOKED ``token_hash`` values. A revocation is recorded
# here BEFORE (and independent of) the on-disk write, so a revoked token stops
# authenticating for the lifetime of THIS process even if ``_save`` fails to
# persist the removal (a read-only/full disk). ``match`` consults this set FIRST,
# so a revoked token can never re-match by reloading a stale registry file. Held
# under its own lock so a revoke never blocks on a registry write.
#
# SCOPE LIMIT (documented honesty): the deny-set is per-process and does NOT
# survive a restart or cross process boundaries. OTHER PROCESSES rely entirely on
# the on-disk file as the source of truth — if ``_save`` failed, those processes
# (and a future restart of this one) will STILL authenticate the "revoked" token
# until disk is writable and the revoke is retried. That is precisely why revoke
# RAISES (→ the endpoint 500s ``revocation persist failed``): the operator is told
# the durable state is stale rather than being lied to with a clean 200.
_deny_lock = threading.Lock()
_revoked_hashes: Set[str] = set()
_revoked_device_ids: Set[str] = set()

_DEVICE_NAME_MAX = 64
_DEFAULT_DEVICE_NAME = "iPhone"
_TOKEN_PREFIX_LEN = 8
_DEFAULT_SCOPES = ["chat", "approve"]
_MAX_DEVICES = 64
_MAX_SESSION_DEVICE_INDEX = 256
_SESSION_DEVICE_INDEX_TTL_SECONDS = 30 * 60

# Strip ASCII + Unicode control chars from a device name before storing it.
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def _device_registry_path() -> Path:
    """Resolve the device-token registry path, honouring HERMES_HOME.

    Mirrors ``push_notify._registry_path`` / ``_la_registry_path``: falls back
    to ``~/.hermes`` if the config package can't be imported (keeps this module
    importable in isolation / tests).
    """
    try:
        from hermes_cli.config import get_hermes_home

        return get_hermes_home() / "device_tokens.json"
    except Exception:  # pragma: no cover - defensive fallback
        return Path(os.path.expanduser("~/.hermes")) / "device_tokens.json"


def _normalize_device_name(raw: Any) -> str:
    """Sanitize a client-supplied device name to a non-empty ≤64-char label.

    Strips control chars, collapses internal whitespace, truncates to 64, and
    defaults to ``"iPhone"`` when the result is empty. Coerces rather than
    rejects (the issue endpoint only 400s if this still yields empty, which it
    cannot for a non-string/empty input — those coerce to the default).
    """
    if not isinstance(raw, str):
        return _DEFAULT_DEVICE_NAME
    cleaned = _CONTROL_RE.sub("", raw)
    cleaned = " ".join(cleaned.split())  # collapse runs of whitespace
    cleaned = cleaned[:_DEVICE_NAME_MAX].strip()
    return cleaned or _DEFAULT_DEVICE_NAME


def _hash_token(token: str) -> str:
    """Return the hex sha256 of a presented/minted token (never stored raw)."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _truncate(token: str) -> str:
    """8-char prefix + '…' for safe logging (mirrors consume_ticket)."""
    return (token[:_TOKEN_PREFIX_LEN] + "…") if token else "<empty>"


# ---------------------------------------------------------------------------
# Registry persistence (atomic 0600 — WITH the chmod the alert saver omits)
# ---------------------------------------------------------------------------


def _load() -> Dict[str, Dict[str, Any]]:
    """Load the registry as ``{device_id: entry}``.

    A missing or corrupt file yields ``{}`` (mirrors ``_load_registry``'s
    corrupt-file fallback) so the list/match paths never 500 on a bad file.
    """
    path = _device_registry_path()
    try:
        raw = path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError):
        return {}
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        _log.warning("device_tokens.json is corrupt; treating as empty")
        return {}
    if not isinstance(data, dict):
        return {}
    out: Dict[str, Dict[str, Any]] = {}
    for did, entry in data.items():
        if (
            isinstance(did, str)
            and isinstance(entry, dict)
            and isinstance(entry.get("token_hash"), str)
        ):
            out[did] = entry
    return out


def _save(entries: Dict[str, Dict[str, Any]]) -> bool:
    """Atomically persist the registry at mode 0600. Returns False on failure.

    Caller (issue/revoke) decides whether a False is fatal: both treat it as
    fatal and raise ``DeviceRegistryError`` (→ endpoint 500), so a persist
    failure NEVER masquerades as success. On revoke the in-process deny-set has
    already killed the token for this process; the raise tells the operator the
    on-disk file is stale (other processes still trust the file).
    """
    path = _device_registry_path()
    try:
        # Device registry holds hashed bearer credentials plus metadata. The temp
        # file must be created at 0600 before writing, not chmod'd only after an
        # atomic replace, to avoid a local TOCTOU exposure under permissive umasks.
        atomic_json_write(path, entries, indent=2, mode=0o600)
        return True
    except OSError as exc:
        _log.warning("Could not persist device_tokens.json: %s", exc)
        return False


# ---------------------------------------------------------------------------
# Public registry operations
# ---------------------------------------------------------------------------


class DeviceRegistryError(Exception):
    """Raised when the registry cannot be persisted (maps to 500 at the edge)."""


class DeviceLimitError(DeviceRegistryError):
    """Raised when issuing would exceed the bounded registry size."""


def issue(device_name: Any = None, platform: Any = "ios") -> Dict[str, Any]:
    """Mint a new device id + token, persist the entry (atomic 0600), and
    return ``{device_id, token, device_name, created_at}``.

    The TOKEN is returned ONCE and never stored (only its sha256 + 8-char
    prefix are persisted). Raises ``DeviceRegistryError`` (→ endpoint 500) if the
    registry write fails — issue MUST fail loud since an un-persisted token is
    unusable: no auth gate in this or any other process could ever match it.
    """
    name = _normalize_device_name(device_name)
    plat = platform if isinstance(platform, str) and platform.strip() else "ios"
    plat = plat.strip()[:32]

    device_id = "dev_" + secrets.token_urlsafe(12)
    token = secrets.token_urlsafe(32)
    now = time.time()
    entry = {
        "token_hash": _hash_token(token),
        "token_prefix": token[:_TOKEN_PREFIX_LEN],
        "device_name": name,
        "platform": plat,
        "created_at": now,
        "last_seen": now,
        "scopes": list(_DEFAULT_SCOPES),
    }

    with _registry_lock:
        registry = _load()
        if len(registry) >= _MAX_DEVICES:
            raise DeviceLimitError("device registry limit reached")
        registry[device_id] = entry
        if not _save(registry):
            raise DeviceRegistryError("could not persist device registry")

    return {
        "device_id": device_id,
        "token": token,
        "device_name": name,
        "created_at": now,
    }


def list_devices() -> List[Dict[str, Any]]:
    """Return the public view of every device, sorted ``last_seen`` desc.

    NEVER includes ``token`` or ``token_hash``. A missing/corrupt registry
    yields ``[]`` (never raises).
    """
    with _registry_lock:
        registry = _load()
    out: List[Dict[str, Any]] = []
    for did, entry in registry.items():
        out.append(
            {
                "device_id": did,
                "device_name": entry.get("device_name", _DEFAULT_DEVICE_NAME),
                "platform": entry.get("platform", "ios"),
                "created_at": float(entry.get("created_at", 0.0) or 0.0),
                "last_seen": float(entry.get("last_seen", 0.0) or 0.0),
                "token_prefix": entry.get("token_prefix", ""),
                # Tolerate absence (legacy/forward-compat) → treat as full scope.
                "scopes": entry.get("scopes", list(_DEFAULT_SCOPES)),
            }
        )
    out.sort(key=lambda d: d["last_seen"], reverse=True)
    return out


def revoke(device_id: str) -> bool:
    """Remove a device entry (atomic 0600, under lock). Returns True if the
    device existed (and is now gone), False if ``device_id`` was unknown.

    REVOCATION DURABILITY (R1-fix finding 3): the removed entry's ``token_hash``
    is recorded in the in-process ``_revoked_hashes`` deny-set BEFORE the disk
    write. ``match`` consults that set first, so the revocation holds for the
    process lifetime EVEN IF ``_save`` fails — the prior behaviour returned True
    while a failed write left the token still on disk, and ``match`` (which
    reloads the file) would keep authenticating it. The LIVE WS cut is handled
    separately by the caller via ``get_device_sockets``.

    Raises ``DeviceRegistryError`` if the on-disk write fails, so the endpoint
    surfaces a 500 ``{"error": "revocation persist failed"}`` instead of falsely
    reporting a clean revoke. Auth is ALREADY correct in THIS process at that
    point (deny-set + the in-memory save target both exclude the token); the raise
    tells the operator the persisted file is stale and a restart would reload it.
    The deny-set does not survive a restart and does NOT cross process boundaries
    — other processes read the on-disk file, so they keep authenticating the token
    until disk is writable and the revoke is retried; the 500 makes that visible.
    """
    with _registry_lock:
        registry = _load()
        entry = registry.get(device_id)
        if entry is None:
            return False
        # Record the deny-hash FIRST so the token is dead the instant we drop it,
        # regardless of whether the disk write below succeeds.
        token_hash = entry.get("token_hash")
        with _deny_lock:
            _revoked_device_ids.add(device_id)
            if isinstance(token_hash, str) and token_hash:
                _revoked_hashes.add(token_hash)
        registry.pop(device_id, None)
        _clear_session_mappings_for_device(device_id)
        if not _save(registry):
            _log.warning(
                "device revoke held in-process (deny-set) but disk write failed "
                "for %s; persisted registry is stale",
                device_id,
            )
            raise DeviceRegistryError("device revoked in-process but disk write failed")
        return True


def match(token: Optional[str]) -> Optional[Dict[str, Any]]:
    """Timing-safe device-token lookup. Returns the device identity dict
    ``{device_id, device_name, token_prefix, scopes}`` on a hit, else None.

    Hashes the presented token and ``hmac.compare_digest``-checks against every
    stored ``token_hash`` (we still compare against all entries even after a
    match to keep the timing flat-ish; the registry is tiny). Bumps the matched
    device's ``last_seen`` best-effort under lock (NOT on a hot loop — only when
    a device token is actually presented, i.e. after the shared token missed).

    Returns None for an empty/oversized/non-string token WITHOUT touching disk,
    so the common shared-token request pays nothing. None NEVER implies the
    shared token is invalid — it only means "not a known device token".
    """
    if not token or not isinstance(token, str):
        return None
    # Bound the work: a urlsafe(32) token is ~43 chars; anything wildly long is
    # not one of ours. Avoids hashing attacker-controlled megabytes.
    if len(token) > 512:
        return None

    presented_hash = _hash_token(token)

    # DENY-SET (R1-fix finding 3): a hash revoked this process lifetime can never
    # re-match, even if a failed persist left it in the on-disk file we reload
    # below. Checked before the registry scan so a revoked token pays nothing.
    with _deny_lock:
        if presented_hash in _revoked_hashes:
            return None

    matched_id: Optional[str] = None
    matched_entry: Optional[Dict[str, Any]] = None

    with _registry_lock:
        registry = _load()
        for did, entry in registry.items():
            stored = entry.get("token_hash", "")
            if isinstance(stored, str) and hmac.compare_digest(
                presented_hash, stored
            ):
                matched_id = did
                matched_entry = entry
                # No early break: keep comparing to avoid leaking position via
                # timing. The registry is small so the cost is negligible.
        if matched_id is not None and matched_entry is not None:
            # Best-effort last_seen bump while we still hold the lock + registry.
            try:
                matched_entry["last_seen"] = time.time()
                registry[matched_id] = matched_entry
                _save(registry)
            except Exception:  # pragma: no cover - best-effort only
                _log.debug("last_seen bump failed for %s", matched_id)

    if matched_id is None or matched_entry is None:
        return None
    return {
        "device_id": matched_id,
        "device_name": matched_entry.get("device_name", _DEFAULT_DEVICE_NAME),
        "token_prefix": matched_entry.get("token_prefix", token[:_TOKEN_PREFIX_LEN]),
        "scopes": matched_entry.get("scopes", list(_DEFAULT_SCOPES)),
    }


def is_device_active(device_id: Optional[str]) -> bool:
    """Return True when ``device_id`` is still present and not revoked locally."""
    if not device_id or not isinstance(device_id, str):
        return False
    with _deny_lock:
        if device_id in _revoked_device_ids:
            return False
    with _registry_lock:
        return device_id in _load()


# ---------------------------------------------------------------------------
# Live-WS-socket index — the one piece of new WS state. Lets revoke cut a
# revoked device's open sockets immediately. Shared-token sockets are NEVER
# indexed (revoking a device must not cut the shared session).
# ---------------------------------------------------------------------------


def register_ws_socket(device_id: str, ws: Any) -> None:
    """Attribute a live WS socket to a device (called via the token-auth
    socket observers when the WS accept path resolved a device identity)."""
    if not device_id:
        return
    with _ws_index_lock:
        _ws_device_sockets.setdefault(device_id, set()).add(ws)


def deregister_ws_socket(device_id: str, ws: Any) -> None:
    """Drop a socket from the index (called on WS close). Idempotent."""
    if not device_id:
        return
    with _ws_index_lock:
        socks = _ws_device_sockets.get(device_id)
        if socks is None:
            return
        socks.discard(ws)
        if not socks:
            _ws_device_sockets.pop(device_id, None)
    _clear_session_mappings_for_ws(ws)


def get_device_sockets(device_id: str) -> List[Any]:
    """Snapshot the live sockets attributed to a device (for the live cut)."""
    if not device_id:
        return []
    with _ws_index_lock:
        return list(_ws_device_sockets.get(device_id, ()))


def _normalize_session_id(session_id: Any) -> str:
    return session_id.strip() if isinstance(session_id, str) else ""


def _session_index_now() -> float:
    return time.monotonic()


def _prune_expired_session_mappings(now: Optional[float] = None) -> None:
    """Drop stale runtime-session correlations while holding session lock."""
    if not _session_device_sockets:
        return
    ttl = _SESSION_DEVICE_INDEX_TTL_SECONDS
    if ttl <= 0:
        _session_device_sockets.clear()
        return
    cutoff = (now if now is not None else _session_index_now()) - ttl
    stale = [
        session_id
        for session_id, (_device_id, _ws, seen_at) in _session_device_sockets.items()
        if seen_at < cutoff
    ]
    for session_id in stale:
        _session_device_sockets.pop(session_id, None)


def _enforce_session_index_bound() -> None:
    """Evict oldest runtime-session correlations over the hard cap."""
    max_entries = max(1, int(_MAX_SESSION_DEVICE_INDEX or 1))
    while len(_session_device_sockets) > max_entries:
        _session_device_sockets.popitem(last=False)


def _device_ids_for_ws_socket(ws: Any) -> List[str]:
    if ws is None:
        return []
    with _ws_index_lock:
        return [
            device_id
            for device_id, sockets in _ws_device_sockets.items()
            if ws in sockets
        ]


def _single_active_device_for_ws_socket(ws: Any) -> Optional[str]:
    device_ids = _device_ids_for_ws_socket(ws)
    if len(device_ids) != 1:
        return None
    device_id = device_ids[0]
    if not is_device_active(device_id):
        return None
    return device_id


def _clear_session_mappings_for_ws(ws: Any) -> None:
    with _session_index_lock:
        stale = [
            session_id
            for session_id, (_device_id, mapped_ws, _seen_at) in _session_device_sockets.items()
            if mapped_ws is ws
        ]
        for session_id in stale:
            _session_device_sockets.pop(session_id, None)


def _clear_session_mappings_for_device(device_id: str) -> None:
    with _session_index_lock:
        stale = [
            session_id
            for session_id, (mapped_device_id, _ws, _seen_at) in _session_device_sockets.items()
            if mapped_device_id == device_id
        ]
        for session_id in stale:
            _session_device_sockets.pop(session_id, None)


def record_session_transport(session_id: Any, transport: Any) -> Optional[Dict[str, Any]]:
    """Correlate a runtime TUI session with a mobile device-token WS, if any.

    The gateway only exposes ``AIAgent(platform="tui")`` for both desktop and
    iOS turns. This helper composes plugin-owned state instead: runtime session
    S is mobile only when its serving transport wraps a WebSocket that is
    already indexed as exactly one live device-token socket. Shared-token
    desktop sessions, missing transports, and ambiguous socket attribution clear
    any prior mapping and return None.
    """
    sid = _normalize_session_id(session_id)
    if not sid:
        return None
    ws = getattr(transport, "_ws", None)
    device_id = _single_active_device_for_ws_socket(ws)
    now = _session_index_now()
    with _session_index_lock:
        _prune_expired_session_mappings(now)
        if device_id is None:
            _session_device_sockets.pop(sid, None)
            return None
        _session_device_sockets[sid] = (device_id, ws, now)
        _session_device_sockets.move_to_end(sid)
        _enforce_session_index_bound()
    return {"device_id": device_id}


def clear_session_transport(session_id: Any = "", transport: Any = None) -> None:
    """Drop session→device correlation for a session or all sessions on a transport."""
    sid = _normalize_session_id(session_id)
    ws = getattr(transport, "_ws", None) if transport is not None else None
    with _session_index_lock:
        if sid:
            mapped = _session_device_sockets.get(sid)
            if ws is None or mapped is None or mapped[1] is ws:
                _session_device_sockets.pop(sid, None)
            return
        if ws is None:
            return
        stale = [
            mapped_session_id
            for mapped_session_id, (_device_id, mapped_ws, _seen_at) in _session_device_sockets.items()
            if mapped_ws is ws
        ]
        for mapped_session_id in stale:
            _session_device_sockets.pop(mapped_session_id, None)


def device_identity_for_session(session_id: Any) -> Optional[Dict[str, Any]]:
    """Return a mobile device identity for a correlated TUI runtime session."""
    sid = _normalize_session_id(session_id)
    if not sid:
        return None
    with _session_index_lock:
        _prune_expired_session_mappings()
        mapped = _session_device_sockets.get(sid)
        if mapped is not None:
            _session_device_sockets.move_to_end(sid)
    if mapped is None:
        return None
    device_id, ws, _seen_at = mapped
    device_ids = _device_ids_for_ws_socket(ws)
    if len(device_ids) != 1 or device_ids[0] != device_id:
        clear_session_transport(sid)
        return None
    if not is_device_active(device_id):
        clear_session_transport(sid)
        return None
    return {"device_id": device_id}


def _reset_for_tests() -> None:
    """Clear the in-process WS index + revoked-hash deny-set (the registry itself
    lives on disk per HERMES_HOME)."""
    with _ws_index_lock:
        _ws_device_sockets.clear()
    with _session_index_lock:
        _session_device_sockets.clear()
    with _deny_lock:
        _revoked_hashes.clear()
        _revoked_device_ids.clear()
