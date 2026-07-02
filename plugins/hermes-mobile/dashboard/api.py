"""hermes-mobile plugin — backend REST routes.

Mounted at ``/api/plugins/hermes-mobile/`` by the dashboard plugin system
(``hermes_cli.web_server._mount_plugin_api_routes``). Route bodies moved
verbatim from ``hermes_cli/web_server.py`` in the ABH-88 de-patch (W1):

* ``POST /upload``                — attachment upload bridge (was /api/upload)
* ``POST /approvals/respond``     — REST approval resolve (was /api/approvals/respond)
* ``GET  /approvals/audit``       — approval audit read   (was /api/approvals/audit)
* ``POST /devices/issue``         — mint per-device token (was /api/devices/issue)
* ``GET  /devices``               — list paired devices   (was /api/devices)
* ``DELETE /devices/{device_id}`` — revoke device         (was /api/devices/{id})
* ``GET  /fs/list`` / ``GET /fs/read`` — sandboxed session-cwd browse
* ``POST/DELETE /push/register`` + ``/push/live-activity`` — APNs registry
  (formerly ``hermes_cli.push_notify.router`` at /api/push/*)

Security note
-------------
Plugin HTTP routes go through the dashboard's auth middleware just like core
API routes (see the kanban plugin's plugin_api.py for the precedent). Every
handler ALSO keeps its explicit in-handler auth check — the same
belt-and-suspenders the routes had before the move. Auth helpers are
resolved lazily from ``hermes_cli.web_server`` (they remain stock seams until
the W2 auth-provider conversion).
"""

from __future__ import annotations

import asyncio
import hashlib
import importlib
import importlib.util
import json as _json
import logging
import os
import re as _re
import secrets
import stat
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from typing import Annotated

_log = logging.getLogger(__name__)

router = APIRouter()

# Directory of the plugin package (parent of dashboard/).
_PLUGIN_DIR = Path(__file__).resolve().parent.parent
_PLUGIN_PKG = "hermes_plugins.hermes_mobile"


def _plugin_module(name: str):
    """Import a sibling module of the hermes-mobile plugin package.

    Prefers the package the stock PluginManager loaded
    (``hermes_plugins.hermes_mobile``); falls back to loading the package from
    this file's parent directory when the dashboard mounts the API without the
    agent-side plugin being enabled (e.g. a bare web_server import in tests).
    """
    if _PLUGIN_PKG not in sys.modules:
        if "hermes_plugins" not in sys.modules:
            import types

            ns_pkg = types.ModuleType("hermes_plugins")
            ns_pkg.__path__ = []  # type: ignore[attr-defined]
            ns_pkg.__package__ = "hermes_plugins"
            sys.modules["hermes_plugins"] = ns_pkg
        spec = importlib.util.spec_from_file_location(
            _PLUGIN_PKG,
            _PLUGIN_DIR / "__init__.py",
            submodule_search_locations=[str(_PLUGIN_DIR)],
        )
        if spec is None or spec.loader is None:  # pragma: no cover - defensive
            raise ImportError(f"cannot load plugin package from {_PLUGIN_DIR}")
        mod = importlib.util.module_from_spec(spec)
        mod.__path__ = [str(_PLUGIN_DIR)]  # type: ignore[attr-defined]
        sys.modules[_PLUGIN_PKG] = mod
        spec.loader.exec_module(mod)
    return importlib.import_module(f"{_PLUGIN_PKG}.{name}")


def _web():
    """The host web_server module (it mounted us; import is always satisfied)."""
    from hermes_cli import web_server

    return web_server


def _has_dashboard_api_auth(request: Request) -> bool:
    return _web()._has_dashboard_api_auth(request)


def _device_has_scope(request: Request, scope: str) -> bool:
    return _web()._device_has_scope(request, scope)


def _is_device_auth(request: Request) -> bool:
    return _web()._is_device_auth(request)


def _request_device(request: Request) -> Optional[dict]:
    return _web()._request_device(request)


# ---------------------------------------------------------------------------
# Attachment upload — bridge for remote clients (mobile/desktop-remote).
#
# The ``image.attach`` RPC takes a *server-local* file path, which works for
# the desktop app spawning a local backend but not for clients on another
# device.  Remote clients POST the bytes here first, then pass the returned
# path to ``image.attach``.  Uploads land in ~/.hermes/uploads/ with opaque
# names; the directory is bounded by _prune_uploads() (count + age).
# ---------------------------------------------------------------------------

_UPLOAD_DIR = Path(os.path.expanduser("~/.hermes")) / "uploads"
_MAX_ATTACHMENT_UPLOAD_BYTES = 25 * 1024 * 1024  # 25 MB
_ATTACHMENT_MULTIPART_OVERHEAD_BYTES = 1024 * 1024
# Mirror of cli._IMAGE_EXTENSIONS minus formats the vision pipeline can't
# read (no HEIC — iOS clients convert to JPEG before uploading).
_UPLOAD_ALLOWED_EXTENSIONS = frozenset({
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tiff", ".tif",
})
_UPLOAD_MAX_FILES = 200
_UPLOAD_MAX_AGE_SECONDS = 7 * 24 * 3600


def _prune_uploads() -> None:
    """Best-effort cleanup so the uploads dir can't grow unbounded."""
    try:
        entries = sorted(
            (p for p in _UPLOAD_DIR.iterdir() if p.is_file()),
            key=lambda p: p.stat().st_mtime,
        )
    except OSError:
        return
    now = time.time()
    excess = len(entries) - _UPLOAD_MAX_FILES
    for index, path in enumerate(entries):
        try:
            too_old = (now - path.stat().st_mtime) > _UPLOAD_MAX_AGE_SECONDS
            if index < excess or too_old:
                path.unlink()
        except OSError:
            continue


@router.post("/upload")
async def upload_attachment(request: Request):
    """Accept a multipart image upload and return its server-local path.

    Gated by the standard /api/ session-token middleware. The returned
    ``path`` is meant to be fed straight into the ``image.attach`` RPC.
    """
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")

    content_length = request.headers.get("content-length")
    if content_length:
        try:
            max_request_bytes = (
                _MAX_ATTACHMENT_UPLOAD_BYTES + _ATTACHMENT_MULTIPART_OVERHEAD_BYTES
            )
            if int(content_length) > max_request_bytes:
                raise HTTPException(
                    status_code=413,
                    detail="Attachment too large (25MB max)",
                )
        except ValueError:
            pass

    form = await request.form()
    upload = form.get("file")
    if upload is None or isinstance(upload, str):
        raise HTTPException(status_code=400, detail="multipart field 'file' required")

    filename = os.path.basename(upload.filename or "")
    ext = Path(filename).suffix.lower()
    if ext not in _UPLOAD_ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=415,
            detail=f"Unsupported attachment type: {ext or '(none)'}",
        )

    data = await upload.read(_MAX_ATTACHMENT_UPLOAD_BYTES + 1)
    if not data:
        raise HTTPException(status_code=400, detail="Empty upload")
    if len(data) > _MAX_ATTACHMENT_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="Attachment too large (25MB max)")

    _UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    dest = _UPLOAD_DIR / f"{secrets.token_hex(16)}{ext}"
    try:
        dest.write_bytes(data)
    except OSError as exc:
        raise HTTPException(status_code=500, detail=f"Could not store upload: {exc}")

    _prune_uploads()
    return {"path": str(dest), "size": len(data)}


# ---------------------------------------------------------------------------
# Approval respond — REST mirror of the WS ``approval.respond`` RPC, so the
# iOS app can resolve a pending approval straight from a notification action
# (background URLSession) without holding a WebSocket open. Keeps the same
# in-process path as the gateway: map the runtime sid → session_key via
# ``tui_gateway.server._sessions`` then resolve_gateway_approval(...).
# ---------------------------------------------------------------------------

class ApprovalRespondBody(BaseModel):
    session_id: str
    choice: str  # "approve" | "deny"
    all: bool = False


@router.post("/approvals/respond")
async def respond_to_approval(body: ApprovalRespondBody, request: Request):
    """Resolve a pending gateway approval for a runtime session.

    Auth mirrors ``/upload`` (the standard dashboard session token). The
    body mirrors the WS ``approval.respond`` params. Returns
    ``{"resolved": true|false}`` (false = nothing pending / already handled),
    404 when the runtime session is gone, 401 on a bad token. Never 500s on a
    moot approval.
    """
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if not _device_has_scope(request, "approve"):
        raise HTTPException(status_code=403, detail="Device token lacks approve scope")

    # "approve" maps to the gateway's "once" decision; anything else denies.
    choice = "once" if body.choice == "approve" else "deny"

    try:
        from tui_gateway.server import _sessions
    except Exception as exc:  # pragma: no cover - gateway import unavailable
        raise HTTPException(status_code=503, detail=f"Gateway unavailable: {exc}")

    session = _sessions.get(body.session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="Unknown session")
    session_key = session.get("session_key")
    if not session_key:
        raise HTTPException(status_code=404, detail="Unknown session")

    # W3a: build the audit context from the resolver's auth identity. A device
    # token sets request.state.device (in _has_valid_session_token); otherwise
    # the shared token resolved it.
    audit = _build_resolve_audit(request, body.session_id, session_key)

    try:
        from tools.approval import resolve_gateway_approval

        resolved = resolve_gateway_approval(
            session_key, choice, resolve_all=body.all, audit=audit
        )
    except Exception:
        # A moot/already-handled approval must never surface as a 500 — the app
        # treats resolved:false as "Already handled".
        _log.debug("approval respond failed", exc_info=True)
        return {"resolved": False}

    return {"resolved": bool(resolved)}


def _build_resolve_audit(
    request: Request, session_id: str, session_key: str
) -> dict:
    """Build the W3a approval-audit dict from a REST resolver's auth context.

    ``request.state.device`` is set by ``_has_valid_session_token`` only on a
    device-token match → ``credential="device"`` + the device fields. Otherwise
    the shared token resolved it → ``credential="shared"``, ``device_id=None``.
    """
    device = getattr(request.state, "device", None)
    if isinstance(device, dict) and device.get("device_id"):
        return {
            "credential": "device",
            "device_id": device.get("device_id"),
            "device_name": device.get("device_name"),
            "token_prefix": device.get("token_prefix"),
            "session_id": session_id,
            "session_key": session_key,
        }
    return {
        "credential": "shared",
        "device_id": None,
        "device_name": None,
        "token_prefix": None,
        "session_id": session_id,
        "session_key": session_key,
    }


# ---------------------------------------------------------------------------
# W3a — per-device pairing tokens. Three mutators + a list, all token-gated
# (the /api/ auth middleware PLUS an explicit in-handler check, matching the
# /approvals/respond precedent). MIGRATION SAFETY: the caller authenticates
# with EITHER the shared token OR an existing device token; issuing is a
# narrower, revocable re-grant of access the caller already holds, never an
# escalation. None of these endpoints can touch or reject the shared token.
# ---------------------------------------------------------------------------


class _DeviceIssueBody(BaseModel):
    device_name: Optional[str] = None
    platform: Optional[str] = "ios"


@router.post("/devices/issue")
async def issue_device_token(request: Request, body: _DeviceIssueBody):
    """Mint a per-device token. Returns the token EXACTLY ONCE; the registry
    stores only its hash + an 8-char prefix. The client MUST persist the token
    to its Keychain immediately — it is never recoverable afterwards."""
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if _is_device_auth(request):
        raise HTTPException(status_code=403, detail="Device tokens cannot issue devices")

    device_tokens = _plugin_module("device_tokens")

    # Normalize defensively; normalization coerces rather than rejects, so a 400
    # here only fires for a pathological input that still collapses to empty.
    name = device_tokens._normalize_device_name(body.device_name)
    if not name:
        return JSONResponse(
            status_code=400, content={"error": "invalid device_name"}
        )

    try:
        result = device_tokens.issue(
            device_name=name, platform=body.platform or "ios"
        )
    except device_tokens.DeviceLimitError:
        return JSONResponse(
            status_code=409,
            content={
                "error": "device limit reached",
                "max_devices": device_tokens._MAX_DEVICES,
            },
        )
    except device_tokens.DeviceRegistryError:
        # Issue MUST fail loud — an un-persisted token would be unusable, so we
        # never return it. Same persist-failure honesty as revoke: a 500 instead
        # of a false 200 carrying a token that no auth gate (in this or any other
        # process) can ever match because it was never written to disk.
        return JSONResponse(
            status_code=500,
            content={"error": "registry persist failed"},
        )

    # The ONLY response that ever carries ``token``.
    return result


@router.get("/devices")
async def list_device_tokens(request: Request):
    """List paired devices (backs the iOS panel + the eager capability probe).

    NEVER returns ``token``/``token_hash``. An empty/corrupt registry → 200
    ``{"devices": []}`` (NOT 404 — the route exists, so the probe classifies it
    ``.available``). The probe relies on this route 404'ing only on a stock
    server with no device routes."""
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if not _device_has_scope(request, "approve"):
        raise HTTPException(status_code=403, detail="Device token lacks approve scope")

    device_tokens = _plugin_module("device_tokens")

    return {"devices": device_tokens.list_devices()}


@router.delete("/devices/{device_id}")
async def revoke_device_token(device_id: str, request: Request):
    """Revoke a device: remove its registry entry (so its next REST + WS auth
    both fail) AND cut any of its live WS sockets immediately (close 4401).

    BINDING: a device can never revoke the shared token — no ``device_id`` maps
    to it, and the shared-token live session is never indexed for the live cut.
    """
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")

    device_tokens = _plugin_module("device_tokens")
    device = _request_device(request)
    if device is not None and device.get("device_id") != device_id:
        raise HTTPException(
            status_code=403,
            detail="Device tokens can only revoke themselves",
        )

    # ``revoke`` records the deny-hash BEFORE the disk write, so a persist failure
    # still revokes the token for this process lifetime (it raises so we can tell
    # the operator the on-disk file is stale). We run the live WS cut in BOTH the
    # clean and the persist-failed path, then 500 only on the persist failure.
    persist_failed = False
    try:
        if not device_tokens.revoke(device_id):
            return JSONResponse(
                status_code=404, content={"error": "unknown device"}
            )
    except device_tokens.DeviceRegistryError:
        # The token is already dead in-process (deny-set); the registry file just
        # could not be rewritten. Surface a 500 so the caller does not believe the
        # revoke durably persisted, but STILL cut the live sockets below.
        persist_failed = True

    # LIVE WS CUT (best-effort): close any open sockets attributed to this
    # device. Sockets that authed with the shared token are NOT in the index,
    # so the shared-token live session is never cut.
    sockets_closed = 0
    for ws in device_tokens.get_device_sockets(device_id):
        try:
            await ws.close(code=4401, reason="device revoked")
            sockets_closed += 1
        except Exception:  # pragma: no cover - socket already gone
            _log.debug("device-revoke WS close failed", exc_info=True)
        finally:
            device_tokens.deregister_ws_socket(device_id, ws)

    if persist_failed:
        # The deny-set already killed the token in-process; the durable write
        # failed (read-only / full disk). Fail loud with a 500 so the operator
        # knows the persisted registry is stale and OTHER processes (which rely
        # on the on-disk file, not this process's deny-set) may still authenticate
        # the token until disk is writable again and the revoke is retried.
        return JSONResponse(
            status_code=500,
            content={
                "error": "revocation persist failed",
                "revoked": True,
                "device_id": device_id,
                "sockets_closed": sockets_closed,
            },
        )

    return {"revoked": True, "device_id": device_id, "sockets_closed": sockets_closed}


@router.get("/approvals/audit")
async def read_approval_audit(
    request: Request, limit: int = 100, session_id: Optional[str] = None
):
    """Read the append-only approval audit log (read-only iOS panel).

    ``limit`` is clamped to [1, 500] (never errors). ``session_id`` optionally
    filters. NEVER returns a full token (records carry only ``token_prefix`` +
    ``device_id``). A missing/corrupt log → ``{"entries": []}`` (200). Never
    500."""
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if not _device_has_scope(request, "approve"):
        raise HTTPException(status_code=403, detail="Device token lacks approve scope")

    audit_log = _plugin_module("audit_log")

    return {"entries": audit_log.read(limit=limit, session_id=session_id)}


# ---------------------------------------------------------------------------
# Session-scoped filesystem browse — GET /fs/list + GET /fs/read.
#
# GREENFIELD for hermes-mobile F4a: no prior REST/RPC surface lists a directory
# or returns a file's bytes under a session cwd (``complete.path`` returns
# autocomplete NAMES only and is not sandboxed). These two read-only endpoints
# back the iOS file browser + text viewer. Auth is the standard dashboard
# session token (mirrors ``/upload`` and ``/approvals/respond``).
#
# SANDBOX: every requested path is resolved against the session cwd ROOT and the
# realpath MUST stay under that root (== root, or starts with root + os.sep).
# Symlinks resolve via realpath BEFORE the prefix check, so a symlink pointing
# out of the tree is rejected. Absolute paths and ``~/`` are refused (unlike
# ``complete.path``). One shared resolver (``_resolve_under_session_cwd``) is the
# single place to audit traversal.
# ---------------------------------------------------------------------------

_MAX_FS_LIST_ENTRIES = 1000
_MAX_FS_READ_BYTES = 1 * 1024 * 1024  # 1 MB — mobile text-viewer scope


class FsSandboxError(Exception):
    """Raised by ``_resolve_under_session_cwd`` on a rejected path.

    Carries an HTTP status + a stable error body so the handlers can translate
    sandbox/lookup failures into the contract-pinned responses without leaking a
    stack trace or 500ing.
    """

    def __init__(self, status_code: int, error: str):
        super().__init__(error)
        self.status_code = status_code
        self.error = error


def _session_cwd_root(session_id: str) -> str:
    """Resolve the cwd ROOT for a LIVE ``session_id``.

    The sid MUST resolve to a session registered in the gateway's ``_sessions``
    map. R1-fix finding 2: an unknown/stale sid raises ``FsSandboxError(404)``
    instead of falling back to ``TERMINAL_CWD`` / ``os.getcwd()`` — that fallback
    leaked the dashboard's OWN workspace to any client presenting a bogus sid
    (and contradicted this endpoint's pinned contract, which says "unknown sid →
    404"). The iOS client always passes its ACTIVE runtime sid and re-resolves it
    on reconnect, so a live app never trips this; a 404 only fires for a stale or
    forged sid, which the app surfaces as "No Active Session".

    A session registered WITHOUT an explicit cwd still resolves: it falls back to
    ``TERMINAL_CWD`` / ``os.getcwd()`` exactly as the gateway's ``_completion_cwd``
    does for a known-but-cwd-less session. The 404 is ONLY for an UNKNOWN sid.
    """
    try:
        from tui_gateway.server import _sessions
    except Exception:
        # Gateway module genuinely unavailable (import error, not a missing sid).
        # We cannot validate the sid against a live session table, so we cannot
        # honour the browse request safely — refuse rather than leak the dash cwd.
        raise FsSandboxError(404, "unknown session")

    sess = _sessions.get(session_id)
    if sess is None:
        # Unknown / stale sid — never fall back to the dashboard workspace.
        raise FsSandboxError(404, "unknown session")

    # Known session: use its cwd, or the gateway's own cwd precedence when the
    # session was registered without an explicit cwd (mirrors _completion_cwd).
    raw = sess.get("cwd") or os.environ.get("TERMINAL_CWD") or os.getcwd()
    return os.path.realpath(os.path.abspath(os.path.expanduser(str(raw))))


def _resolve_under_session_cwd(session_id: str, rel_path: str) -> Tuple[str, str]:
    """Resolve ``rel_path`` under the session cwd ROOT, sandboxed.

    Returns ``(root, abspath)`` where ``root`` is the absolute realpath'd session
    cwd and ``abspath`` is the realpath'd target. Raises ``FsSandboxError`` with
    the contract status/body when the target escapes the root.

    The escape check is performed on the REALPATH (symlinks already resolved),
    so a symlink inside the tree that points outside it is rejected. Absolute
    paths and ``~`` in ``rel_path`` are NOT honoured as roots: they are joined
    onto ``root`` so ``path=/etc/passwd`` resolves to ``<root>/etc/passwd`` (a
    missing path → 404), and a genuine ``../`` traversal trips the prefix guard.
    """
    root = _session_cwd_root(session_id)
    rel = rel_path or ""
    if "\x00" in rel:
        raise FsSandboxError(400, "invalid path")
    # Strip a leading separator so an "absolute"-looking path is treated as a
    # sub-path of root rather than replacing it (os.path.join would otherwise
    # discard root entirely on an absolute second arg).
    rel = rel.lstrip("/").lstrip("\\")
    try:
        candidate = os.path.realpath(os.path.join(root, rel))
    except (OSError, ValueError):
        raise FsSandboxError(400, "invalid path")
    if candidate != root and not candidate.startswith(root + os.sep):
        raise FsSandboxError(403, "path escapes session root")
    return root, candidate


@router.get("/fs/list")
async def fs_list(request: Request, session_id: str = "", path: str = ""):
    """List a directory under a session's cwd (sandboxed, read-only).

    Query params: ``session_id`` (required — resolves the cwd ROOT), ``path``
    (optional relative sub-path; default = root). Entries are sorted dirs-first
    then by name, capped at 1000 (``truncated:true`` when capped). Dotfiles are
    included; the client decides display. Errors: 400 missing session_id, 401
    bad token, 403 path escape, 404 not a directory / unknown sid.
    """
    # Belt-and-suspenders: the /api/ middleware already gates this, but mirror
    # the explicit in-handler check used by /approvals/respond.
    if not _has_dashboard_api_auth(request):
        return JSONResponse(status_code=401, content={"error": "unauthorized"})

    if not session_id:
        return JSONResponse(
            status_code=400, content={"error": "session_id required"}
        )

    try:
        root, abspath = _resolve_under_session_cwd(session_id, path)
    except FsSandboxError as exc:
        return JSONResponse(status_code=exc.status_code, content={"error": exc.error})

    if not os.path.isdir(abspath):
        return JSONResponse(status_code=404, content={"error": "not a directory"})

    try:
        names = os.listdir(abspath)
    except OSError:
        return JSONResponse(status_code=404, content={"error": "not a directory"})

    entries: List[Dict[str, Any]] = []
    truncated = False
    for name in names:
        full = os.path.join(abspath, name)
        try:
            child_real = os.path.realpath(full)
        except (OSError, ValueError):
            child_real = ""
        if child_real != root and not child_real.startswith(root + os.sep):
            # A symlink or race-resolved child points outside the session root.
            # Surface the name without following target metadata.
            entries.append({
                "name": name,
                "is_dir": False,
                "size": 0,
                "modified": 0.0,
            })
            continue
        try:
            st = os.stat(full)  # follow symlinks for type/size/mtime
            is_dir = stat.S_ISDIR(st.st_mode)
            entries.append({
                "name": name,
                "is_dir": is_dir,
                "size": 0 if is_dir else int(st.st_size),
                "modified": float(st.st_mtime),
            })
        except OSError:
            # Broken symlink / race: surface the name without metadata rather
            # than dropping it or 500ing.
            entries.append({
                "name": name,
                "is_dir": False,
                "size": 0,
                "modified": 0.0,
            })

    # dirs-first, then case-insensitive name (stable for the client).
    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower(), e["name"]))
    if len(entries) > _MAX_FS_LIST_ENTRIES:
        entries = entries[:_MAX_FS_LIST_ENTRIES]
        truncated = True

    result: Dict[str, Any] = {
        "root": root,
        "path": path or "",
        "entries": entries,
    }
    if truncated:
        result["truncated"] = True
    return result


def _decode_truncated_utf8(head: bytes) -> Optional[str]:
    """Decode ``head`` (a cap-truncated prefix) as UTF-8, tolerating a trailing
    partial multibyte sequence at the cut.

    A clean UTF-8 file that simply exceeds the cap can be sliced mid-codepoint;
    naive ``decode("utf-8")`` would then raise and the file would be misreported
    as binary/over-cap. We retry after trimming up to 3 trailing bytes (the max
    length of an unfinished UTF-8 sequence). Returns the text, or ``None`` when
    the bytes are genuinely not UTF-8 (real binary) — the caller maps ``None`` to
    a 413 in the over-cap path.
    """
    try:
        return head.decode("utf-8")
    except UnicodeDecodeError as exc:
        # Only forgive a partial sequence at the very END (the truncation cut),
        # never a decode error in the interior — that is real binary.
        if exc.start >= len(head) - 3 and exc.end == len(head):
            try:
                return head[: exc.start].decode("utf-8")
            except UnicodeDecodeError:
                return None
        return None


@router.get("/fs/read")
async def fs_read(request: Request, session_id: str = "", path: str = ""):
    """Read a file's contents under a session's cwd (sandboxed, read-only).

    Query params: ``session_id`` (required), ``path`` (required, relative to the
    cwd root). Hard cap ``_MAX_FS_READ_BYTES`` (1 MB): above it → 413. A large
    BUT decodable text file is NOT 413'd — it is truncated to the cap and flagged
    ``truncated:true``. UTF-8 decode → ``encoding:"utf-8"`` with ``content``;
    otherwise → ``encoding:"binary"`` with ``content:null`` (no base64 in v1).
    Errors: 400 missing session_id, 401 bad token, 403 escape, 404 not a file.
    """
    if not _has_dashboard_api_auth(request):
        return JSONResponse(status_code=401, content={"error": "unauthorized"})

    if not session_id:
        return JSONResponse(
            status_code=400, content={"error": "session_id required"}
        )
    if not path:
        return JSONResponse(status_code=400, content={"error": "path required"})

    try:
        _root, abspath = _resolve_under_session_cwd(session_id, path)
    except FsSandboxError as exc:
        return JSONResponse(status_code=exc.status_code, content={"error": exc.error})

    if not os.path.isfile(abspath):
        return JSONResponse(status_code=404, content={"error": "not a file"})

    try:
        size = int(os.path.getsize(abspath))
    except OSError:
        return JSONResponse(status_code=404, content={"error": "not a file"})

    if size > _MAX_FS_READ_BYTES:
        # A large-but-text file is truncated + flagged below rather than hard
        # 413'd. Only refuse outright when it can't be decoded as UTF-8.
        try:
            with open(abspath, "rb") as fh:
                head = fh.read(_MAX_FS_READ_BYTES)
        except OSError:
            return JSONResponse(status_code=404, content={"error": "not a file"})
        text = _decode_truncated_utf8(head)
        if text is None:
            return JSONResponse(
                status_code=413, content={"error": "file too large", "size": size}
            )
        return {
            "path": path,
            "size": size,
            "encoding": "utf-8",
            "content": text,
            "truncated": True,
        }

    try:
        with open(abspath, "rb") as fh:
            data = fh.read(_MAX_FS_READ_BYTES)
    except OSError:
        return JSONResponse(status_code=404, content={"error": "not a file"})

    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return {
            "path": path,
            "size": size,
            "encoding": "binary",
            "content": None,
        }

    return {
        "path": path,
        "size": size,
        "encoding": "utf-8",
        "content": text,
        "truncated": False,
    }


# ---------------------------------------------------------------------------
# APNs push registration (formerly ``hermes_cli.push_notify.router`` mounted
# at /api/push/*; now plugin-owned at .../push/*). The engine lives in this
# plugin's ``push_engine.py``; sending stays dormant until HERMES_PUSH_ENABLED
# + key file (see push_engine module docstring).
# ---------------------------------------------------------------------------


class PushRegisterBody(BaseModel):
    token: str
    platform: str = "ios"
    env: str = ""  # "sandbox" | "production"; empty → server default
    # Per-event opt-in subset of ["approval","clarify","turn_complete"].
    # None/absent → all events (legacy entries keep working).
    events: Optional[List[str]] = None


class PushUnregisterBody(BaseModel):
    token: str


class LiveActivityBody(BaseModel):
    token: str
    session_id: str
    env: str = ""  # "sandbox" | "production"; empty → server default


@router.post("/push/register")
async def register_push_token(body: PushRegisterBody, request: Request) -> Dict[str, Any]:
    """Register an iOS APNs device token for server push."""
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    engine = _plugin_module("push_engine")
    if not engine.register_token(
        body.token, platform=body.platform, env=body.env, events=body.events
    ):
        raise HTTPException(status_code=400, detail="Invalid device token")
    return {"ok": True}


@router.delete("/push/register")
async def unregister_push_token(body: PushUnregisterBody, request: Request) -> Dict[str, Any]:
    """Unregister a previously-registered device token."""
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    engine = _plugin_module("push_engine")
    removed = engine.unregister_token(body.token)
    return {"ok": True, "removed": removed}


@router.post("/push/live-activity")
async def register_live_activity(body: LiveActivityBody, request: Request) -> Dict[str, Any]:
    """Register (upsert) a Live Activity push token for a session."""
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    engine = _plugin_module("push_engine")
    if not engine.register_live_activity_token(
        body.session_id, body.token, env=body.env
    ):
        raise HTTPException(
            status_code=400, detail="Invalid Live Activity token or session_id"
        )
    return {"ok": True}


@router.delete("/push/live-activity")
async def unregister_live_activity(body: LiveActivityBody, request: Request) -> Dict[str, Any]:
    """Unregister a session's Live Activity push token."""
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    engine = _plugin_module("push_engine")
    removed = engine.unregister_live_activity_token(body.session_id)
    return {"ok": True, "removed": removed}


# ---------------------------------------------------------------------------
# Session full-text search — GET /sessions/search
#
# Read-only FTS5-backed search across all session messages.  Uses
# ``SessionDB(read_only=True).search_messages()`` — the same FTS5 index the
# desktop's role-scoped search uses (upstream ABH upstream PR).  The endpoint
# is entirely plugin-side: zero stock-core edits.
#
# Params: q (required), limit (default 20, max 100), offset (default 0),
#         sort (newest|oldest|rank — default rank = BM25 relevance),
#         role (user|assistant|tool — optional, repeatable).
#
# Response: {query, results[{session_id, session_title, session_started_at,
#            message_id, role, snippet, timestamp, context}], count, offset}
#
# ``count`` is the row count of THIS page (len(results)), not a DB grand total —
# SessionDB.search_messages does not run a separate COUNT query and we do not
# add one.  Clients paginate by bumping offset until results is empty.
#
# IMPORTANT — _fts_enabled probe:
# SessionDB.__init__ skips _init_schema (and therefore the FTS probe that sets
# _fts_enabled) when read_only=True.  This leaves _fts_enabled=False, which
# causes search_messages() to return [] unconditionally even though the FTS5
# table is fully queryable on a read-only connection.  Plugin-clean fix:
# probe _fts_table_exists() after opening the read-only connection and set
# _fts_enabled=True when the table is present.  This is plugin-only — we do
# NOT modify hermes_state.py.
#
# IMPORTANT — session_title lookup:
# search_messages() SELECT does not return s.title.  We look it up with a
# separate read-only query after collecting the matching session_ids, then join
# in Python.  We do NOT modify search_messages (it is stock + shared with the
# desktop search path).
# ---------------------------------------------------------------------------

_SEARCH_LIMIT_MAX = 100
_SEARCH_LIMIT_DEFAULT = 20


@router.get("/sessions/search")
async def search_sessions(
    request: Request,
    q: Optional[str] = None,
    limit: int = _SEARCH_LIMIT_DEFAULT,
    offset: int = 0,
    sort: Optional[str] = None,
    role: Annotated[Optional[List[str]], Query()] = None,
):
    """Full-text search across all session messages (read-only, FTS5).

    ``q`` is required; missing or empty → 400. Auth is the standard dashboard
    session token. ``sort`` accepts ``newest``, ``oldest``, or ``rank``
    (BM25 relevance, the default). ``role`` may be repeated (e.g.
    ``?role=user&role=assistant``). A malformed FTS5 query is sanitised by
    ``SessionDB._sanitize_fts5_query`` and returns a graceful 200 empty result
    rather than a 500. ``count`` in the response is the page size (not a grand
    total); paginate by bumping ``offset`` until ``results`` is empty.
    """
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")

    if not q or not q.strip():
        return JSONResponse(
            status_code=400, content={"error": "q is required"}
        )

    # Clamp limit.
    try:
        limit = int(limit)
    except (TypeError, ValueError):
        limit = _SEARCH_LIMIT_DEFAULT
    limit = max(1, min(limit, _SEARCH_LIMIT_MAX))

    # Normalise offset — clamp to [0, 500] (mirrors the stock endpoint cap;
    # prevents a huge offset from driving an unbounded FTS scan / DoS).
    try:
        offset = int(offset)
    except (TypeError, ValueError):
        offset = 0
    offset = max(0, min(offset, 500))

    # Normalise sort: pass None (BM25) for any unrecognised value including
    # the explicit "rank" alias so the DB default applies.
    sort_norm: Optional[str]
    if sort and sort.strip().lower() in ("newest", "oldest"):
        sort_norm = sort.strip().lower()
    else:
        sort_norm = None

    # role is already a list from FastAPI query-param binding (repeatable).
    role_filter = [r.strip() for r in (role or []) if r and r.strip()] or None

    from hermes_state import SessionDB, DEFAULT_DB_PATH

    if not DEFAULT_DB_PATH.exists():
        raise HTTPException(status_code=503, detail="state.db unavailable")

    db = None
    try:
        db = SessionDB(read_only=True)

        # FIX #1 — enable FTS on the read-only connection.
        # SessionDB skips _init_schema (and the FTS probe) when read_only=True,
        # so _fts_enabled stays False even though the FTS5 table is fully
        # queryable.  Probe the table directly and set the flag so
        # search_messages can run.  Plugin-only: no hermes_state edit.
        if not db._fts_enabled and db._fts_table_exists("messages_fts"):
            db._fts_enabled = True

        # Exclude sub-agent "tool" source sessions — same rationale as session.list.
        matches = db.search_messages(
            query=q.strip(),
            exclude_sources=["tool"],
            role_filter=role_filter,
            limit=limit,
            offset=offset,
            sort=sort_norm,
        )

        # FIX #2 — look up session titles separately.
        # search_messages SELECT does not return s.title (and we do not modify
        # that query — it is stock + shared).  Collect the distinct session_ids
        # from this page and fetch their titles in one query.
        title_map: Dict[str, str] = {}
        session_ids = list({m["session_id"] for m in matches if m.get("session_id")})
        if session_ids:
            placeholders = ",".join("?" for _ in session_ids)
            cur = db._conn.execute(
                f"SELECT id, title FROM sessions WHERE id IN ({placeholders})",
                session_ids,
            )
            for row in cur.fetchall():
                title_map[row["id"]] = row["title"] or ""

    except Exception as exc:
        _log.warning("sessions/search failed: %s", exc)
        raise HTTPException(status_code=503, detail="search failed")
    finally:
        try:
            if db is not None and getattr(db, "_conn", None) is not None:
                db._conn.close()
        except Exception:
            pass

    results = []
    for m in matches:
        sid = m.get("session_id") or ""
        results.append({
            "session_id": sid,
            "session_title": title_map.get(sid, ""),
            "session_started_at": m.get("session_started") or 0,
            "message_id": m.get("id"),
            "role": m.get("role"),
            "snippet": m.get("snippet") or "",
            "timestamp": m.get("timestamp") or 0,
            "context": m.get("context") or [],
        })

    return {
        "query": q.strip(),
        "results": results,
        "count": len(results),
        "offset": offset,
    }


# ---------------------------------------------------------------------------
# Transcript delta-sync — incremental message fetch for the iOS on-device mirror.
#
# The iOS app caches each session's transcript in SQLite + a per-session cursor.
# Today it refetches the FULL transcript on every change (the stock
# /api/sessions/{id}/messages takes no params). This route serves only the
# missing tail when the client's cached prefix is provably unchanged, else the
# full transcript for a clean re-seed. 100% plugin-side: read-only against the
# stock state.db (no write lock, no schema change, no stock-file edit). The
# generation guard is DERIVED read-only — see transcript_sync.decide_delta.
#
# Response rows mirror the stock endpoint exactly (so StoredMessage parses both
# the same), plus is_delta / prefix_count / max_id for the cursor handshake.
# ---------------------------------------------------------------------------


@router.get("/sessions/{session_id}/messages")
async def session_messages_delta(
    session_id: str,
    request: Request,
    after_id: int = 0,
    prefix_count: int = -1,
    shape: str = "full",
):
    """Incremental transcript fetch. ``after_id`` + ``prefix_count`` are the
    client's cursor; omit them (cold fetch) to get the full transcript. The
    ``shape`` param is reserved for skeleton/light tiering (Phase 4); ``full`` for
    now. Returns ``{session_id, is_delta, prefix_count, max_id, shape, messages}``.
    """
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")

    from hermes_state import SessionDB, DEFAULT_DB_PATH

    if not DEFAULT_DB_PATH.exists():
        raise HTTPException(status_code=503, detail="state.db unavailable")

    db = None
    try:
        db = SessionDB(read_only=True)
        full = db.get_messages(session_id)
    except Exception as exc:  # pragma: no cover - defensive
        _log.warning("session_messages_delta read failed for %s: %s", session_id, exc)
        raise HTTPException(status_code=503, detail="transcript read failed")
    finally:
        # Best-effort close of the per-request read-only connection (no write lock
        # held; GC would also collect it, but close promptly under polling load).
        try:
            if db is not None and getattr(db, "_conn", None) is not None:
                db._conn.close()
        except Exception:
            pass

    transcript_sync = _plugin_module("transcript_sync")
    is_delta, messages, total, max_id = transcript_sync.decide_delta(
        full, after_id, prefix_count
    )
    # Phase 4: tier the payload (skeleton/light) for a faster cold-open. Rows are
    # never dropped, so prefix_count/max_id (the cursor) are unaffected by shaping.
    messages = transcript_sync.shape_messages(messages, shape)
    return {
        "session_id": session_id,
        "is_delta": is_delta,
        "prefix_count": total,
        "max_id": max_id,
        "shape": shape if shape in ("skeleton", "light") else "full",
        "messages": messages,
    }


# ---------------------------------------------------------------------------
# Artifacts gallery — GET /artifacts
#
# Cross-session scan for images, file paths, and URLs found in message
# transcripts.  Entirely plugin-side: read-only against state.db, zero
# stock-core edits.
#
# Params:
#   type   — all | images | files | links (default: all)
#   limit  — max results per page (default 50, max 200)
#   offset — pagination cursor (default 0)
#   q      — optional substring filter applied to url_or_path / filename
#
# Response:
#   {type, results:[{session_id, session_title, message_id, kind, url_or_path,
#                    filename?, mime?, size?, snippet?, timestamp}],
#    total, offset}
#
# Extraction strategy (pure / deterministic, no FTS needed):
#   images — multimodal content parts whose "type" is "image" or "image_url"
#             (content stored as "\x00json:..." JSON-encoded list of parts)
#   files  — tool_calls JSON whose function.arguments contains path-like keys
#             ("path", "file_path", "filepath", "filename") pointing to
#             non-trivially-short strings that start with "/" or "~/"
#   links  — URL regex (http/https) over plain-text prose in any role's
#             content field
#
# All extraction helpers are pure functions so they are directly unit-testable
# and composable.
# ---------------------------------------------------------------------------

_ARTIFACTS_LIMIT_MAX = 200
_ARTIFACTS_LIMIT_DEFAULT = 50

# Multimodal part types that represent visual/attachment artifacts.
_IMAGE_PART_TYPES = frozenset(("image", "image_url", "document"))

# Tool-call argument keys whose values are expected to be file paths.
_FILE_PATH_KEYS = frozenset(("path", "file_path", "filepath", "filename", "output_path"))

# Minimum length for a value to count as a "real" file path (avoids "a", etc.)
_FILE_PATH_MIN_LEN = 3

_URL_RE = _re.compile(r"https?://[^\s\"'<>()[\]{},;\\]+", _re.IGNORECASE)
_CONTENT_JSON_PREFIX = "\x00json:"


def _decode_content_local(raw: Any) -> Any:
    """Decode a potentially JSON-prefixed content field without importing
    hermes_state.  Mirrors ``SessionDB._decode_content`` but kept plugin-local
    so we have zero coupling to the stock internals beyond what the DB schema
    exposes.
    """
    if isinstance(raw, str) and raw.startswith(_CONTENT_JSON_PREFIX):
        try:
            return _json.loads(raw[len(_CONTENT_JSON_PREFIX):])
        except Exception:
            return raw
    return raw


def _extract_images(row: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Return image artifact dicts found in one message row.

    Handles both top-level multimodal lists and nested ``content`` lists inside
    parts (e.g. Claude document parts).  Skips malformed / unexpected shapes
    silently.
    """
    artifacts: List[Dict[str, Any]] = []
    raw_content = row.get("content")
    if not raw_content:
        return artifacts
    content = _decode_content_local(raw_content)
    if not isinstance(content, list):
        return artifacts

    for part in content:
        # Per-part try/except: one malformed part must not drop the rest.
        try:
            if not isinstance(part, dict):
                continue
            ptype = (part.get("type") or "").lower()
            if ptype not in _IMAGE_PART_TYPES:
                continue

            url_or_path = ""
            filename = None
            mime = None
            size = None

            if ptype in ("image", "image_url"):
                # image_url parts: {"type":"image_url","image_url":{"url":"..."}}
                # image parts (base64): {"type":"image","source":{"type":"base64","media_type":"...","data":"..."}}
                img_block = part.get("image_url") or part.get("source") or {}
                raw_url = img_block.get("url")
                if raw_url:
                    url_or_path = raw_url
                else:
                    # data is base64; only safe to slice if it is a string.
                    raw_data = img_block.get("data")
                    url_or_path = raw_data[:80] if isinstance(raw_data, str) else ""
                mime = img_block.get("media_type")
            elif ptype == "document":
                # Document attachments: {"type":"document","source":{"type":"url","url":"..."}}
                src = part.get("source") or {}
                raw_url = src.get("url")
                if raw_url:
                    url_or_path = raw_url
                else:
                    raw_data = src.get("data")
                    url_or_path = raw_data[:80] if isinstance(raw_data, str) else ""
                mime = src.get("media_type")
                filename = part.get("name") or part.get("title")
                size = part.get("size")

            if not url_or_path:
                continue

            artifacts.append({
                "kind": "image",
                "url_or_path": url_or_path,
                "filename": filename,
                "mime": mime,
                "size": size,
                "snippet": None,
            })
        except Exception:
            # Skip this part; continue extracting from remaining parts.
            continue

    return artifacts


def _extract_files(row: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Return file-path artifact dicts found in a tool-call message row.

    Scans ``tool_calls`` (JSON string), extracting function.arguments values
    for recognised path-like keys.  Falls back to scanning ``content`` for
    tool-result rows (role=tool) that carry a path key in their JSON body.
    """
    artifacts: List[Dict[str, Any]] = []

    def _push_path(raw_path: Any) -> None:
        if not isinstance(raw_path, str):
            return
        p = raw_path.strip()
        if len(p) < _FILE_PATH_MIN_LEN:
            return
        if not (p.startswith("/") or p.startswith("~/") or p.startswith(".")):
            return
        fname = Path(p).name or None
        artifacts.append({
            "kind": "file",
            "url_or_path": p,
            "filename": fname,
            "mime": None,
            "size": None,
            "snippet": None,
        })

    # Scan tool_calls JSON (assistant messages that call tools).
    raw_tc = row.get("tool_calls")
    if raw_tc:
        try:
            tc_list = _json.loads(raw_tc) if isinstance(raw_tc, str) else raw_tc
            if isinstance(tc_list, list):
                for tc in tc_list:
                    if not isinstance(tc, dict):
                        continue
                    func = tc.get("function") or {}
                    raw_args = func.get("arguments") or "{}"
                    try:
                        args = _json.loads(raw_args) if isinstance(raw_args, str) else raw_args
                    except Exception:
                        continue
                    if not isinstance(args, dict):
                        continue
                    for key, val in args.items():
                        if key.lower() in _FILE_PATH_KEYS:
                            _push_path(val)
        except Exception:
            pass

    # Scan tool result content (role=tool, plain JSON or multimodal list).
    raw_content = row.get("content")
    if raw_content:
        content = _decode_content_local(raw_content)
        candidates: List[Any] = content if isinstance(content, list) else [content]
        for part in candidates:
            if isinstance(part, dict):
                for key in _FILE_PATH_KEYS:
                    _push_path(part.get(key))
            elif isinstance(part, str):
                try:
                    obj = _json.loads(part)
                    if isinstance(obj, dict):
                        for key in _FILE_PATH_KEYS:
                            _push_path(obj.get(key))
                except Exception:
                    pass

    return artifacts


def _extract_links(row: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Return URL artifact dicts found in the plain-text portions of a message.

    Matches http/https URLs in any text part of the content (including plain
    string content) and in tool result content.  Skips data URIs and
    truncated base64 blobs.
    """
    artifacts: List[Dict[str, Any]] = []

    raw_content = row.get("content")
    if not raw_content:
        return artifacts
    content = _decode_content_local(raw_content)

    texts: List[str] = []
    if isinstance(content, str):
        texts.append(content)
    elif isinstance(content, list):
        for part in content:
            if isinstance(part, str):
                texts.append(part)
            elif isinstance(part, dict):
                ptype = (part.get("type") or "").lower()
                if ptype == "text":
                    texts.append(part.get("text") or "")
                elif ptype in ("tool_result", "tool_use"):
                    # Nested content arrays in tool_result parts.
                    inner = part.get("content") or []
                    if isinstance(inner, str):
                        texts.append(inner)
                    elif isinstance(inner, list):
                        for ip in inner:
                            if isinstance(ip, dict) and ip.get("type") == "text":
                                texts.append(ip.get("text") or "")

    seen: set = set()
    for text in texts:
        for m in _URL_RE.finditer(text):
            url = m.group(0).rstrip(".,;:!?)")
            if url in seen or url.startswith("data:"):
                continue
            seen.add(url)
            snippet_start = max(0, m.start() - 60)
            snippet = text[snippet_start: m.start() + len(url) + 60].strip()
            artifacts.append({
                "kind": "link",
                "url_or_path": url,
                "filename": None,
                "mime": None,
                "size": None,
                "snippet": snippet[:200],
            })

    return artifacts


_ARTIFACT_EXTRACTORS: Dict[str, Any] = {
    "images": _extract_images,
    "files": _extract_files,
    "links": _extract_links,
}


# Maximum artifact matches to scan before stopping the total count.  When hit,
# ``total_capped`` is True in the response (same tradeoff as search_sessions
# which returns a page-size ``count`` rather than a grand total).  Caps CPU
# cost on large DBs: at 10× the max page size the iOS client has ample data
# for pagination decisions without a full 168k-row scan.
_ARTIFACTS_SCAN_CAP = 2000


def _scan_artifacts_sync(
    db_path: "Path",
    type_norm: str,
    limit: int,
    offset: int,
    q_lower: "Optional[str]",
) -> Dict[str, Any]:
    """Blocking artifact scan — run via asyncio.to_thread, never on the event loop.

    Opens the DB via URI read-only mode (``mode=ro``) with a 1s timeout so it
    never acquires a write lock and is structurally incapable of mutating the
    live :9119 DB even under a code bug.

    Uses a streaming row-by-row cursor that stops collecting after
    ``offset + limit`` matching artifacts have been found (O(limit) memory).
    Continues scanning until ``total == _ARTIFACTS_SCAN_CAP`` to report an
    accurate count for pagination, then stops early and sets ``total_capped``
    so the iOS client can display "2000+" rather than waiting for a full
    table scan on a 168k-row DB.
    """
    import sqlite3

    active_extractors: List[Tuple[str, Any]]
    if type_norm == "all":
        active_extractors = list(_ARTIFACT_EXTRACTORS.items())
    else:
        active_extractors = [(type_norm, _ARTIFACT_EXTRACTORS[type_norm])]

    # MUSTFIX-A: URI read-only + 1s timeout — structurally enforces no writes,
    # no write-lock contention with the running WAL backend, and matches the
    # hermes_state.py:625 RO open contract (file:{path}?mode=ro).
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=1.0)
    conn.row_factory = sqlite3.Row
    try:
        # Streaming cursor — fetchone() so we never load the full table.
        # active=1 filters rewound/soft-deleted turns (same as get_messages /
        # search_messages).  No ORDER BY — avoids a full temp B-tree; the
        # table is naturally ordered by insertion rowid which tracks time well
        # enough for an artifact gallery.
        cur = conn.execute(
            """
            SELECT m.id, m.session_id, m.role, m.content, m.tool_calls, m.timestamp
            FROM messages m
            JOIN sessions s ON s.id = m.session_id
            WHERE m.active = 1
              AND (s.source IS NULL OR s.source != 'tool')
            """
        )

        # Collect session titles lazily as we encounter new session ids.
        title_cache: Dict[str, str] = {}

        def _get_title(sid: str) -> str:
            if sid not in title_cache:
                t_cur = conn.execute(
                    "SELECT title FROM sessions WHERE id = ?", (sid,)
                )
                t_row = t_cur.fetchone()
                title_cache[sid] = (t_row["title"] or "") if t_row else ""
            return title_cache[sid]

        # Two-phase accumulation:
        #   Phase 1 (skip)   : discard the first ``offset`` matching artifacts.
        #   Phase 2 (collect): collect the next ``limit`` into ``page``.
        #   Phase 3 (count)  : continue scanning until total == SCAN_CAP, then
        #                      stop early and set total_capped=True.
        skipped = 0
        page: List[Dict[str, Any]] = []
        total = 0
        total_capped = False

        while True:
            raw = cur.fetchone()
            if raw is None:
                break
            row = dict(raw)
            sid = row.get("session_id") or ""
            msg_id = row.get("id")
            ts = row.get("timestamp") or 0

            for _kind, extractor in active_extractors:
                try:
                    hits = extractor(row)
                except Exception:
                    hits = []
                for hit in hits:
                    if q_lower:
                        url_l = (hit.get("url_or_path") or "").lower()
                        fn_l = (hit.get("filename") or "").lower()
                        if q_lower not in url_l and q_lower not in fn_l:
                            continue
                    total += 1
                    if skipped < offset:
                        skipped += 1
                    elif len(page) < limit:
                        page.append({
                            "session_id": sid,
                            "session_title": _get_title(sid),
                            "message_id": msg_id,
                            "kind": hit["kind"],
                            "url_or_path": hit["url_or_path"],
                            "filename": hit.get("filename"),
                            "mime": hit.get("mime"),
                            "size": hit.get("size"),
                            "snippet": hit.get("snippet"),
                            "timestamp": ts,
                        })
                    # MUSTFIX-B: cap the total-count scan so we don't do a
                    # full per-row JSON-decode+regex over 168k rows on every
                    # request. Stop once we've counted SCAN_CAP matches.
                    if total >= _ARTIFACTS_SCAN_CAP:
                        total_capped = True
                        break
                if total_capped:
                    break
            if total_capped:
                break
    finally:
        try:
            conn.close()
        except Exception:
            pass

    return {"results": page, "total": total, "total_capped": total_capped}


@router.get("/artifacts")
async def artifacts_gallery(
    request: Request,
    type: str = "all",
    limit: int = _ARTIFACTS_LIMIT_DEFAULT,
    offset: int = 0,
    q: Optional[str] = None,
):
    """Cross-session artifact gallery (images, files, links).

    Scans message transcripts plugin-side (read-only) for:
    - ``images`` — multimodal content parts of type image/image_url/document
    - ``files``  — tool-call arguments containing path-like keys
    - ``links``  — http/https URLs found in prose content

    ``type`` selects which kinds to include (``all`` = all three).
    ``q`` filters by substring match on ``url_or_path`` / ``filename``.
    Pagination via ``limit`` / ``offset``; ``total`` is the matched-result
    count before pagination.

    The blocking scan runs off the event loop via ``asyncio.to_thread`` so it
    cannot pin the dashboard's async request loop.  The SQL cursor streams
    row-by-row and stops collecting after ``offset + limit`` matches, capping
    peak memory regardless of DB size.
    """
    import asyncio

    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")

    # Validate type.
    type_norm = (type or "all").strip().lower()
    if type_norm not in ("all", "images", "files", "links"):
        raise HTTPException(
            status_code=400,
            detail="type must be one of: all, images, files, links",
        )

    # Clamp limit.
    try:
        limit = int(limit)
    except (TypeError, ValueError):
        limit = _ARTIFACTS_LIMIT_DEFAULT
    limit = max(1, min(limit, _ARTIFACTS_LIMIT_MAX))

    # Normalise offset.
    try:
        offset = int(offset)
    except (TypeError, ValueError):
        offset = 0
    offset = max(0, offset)

    q_lower = q.strip().lower() if q and q.strip() else None

    from hermes_state import DEFAULT_DB_PATH

    if not DEFAULT_DB_PATH.exists():
        raise HTTPException(status_code=503, detail="state.db unavailable")

    db_path = DEFAULT_DB_PATH
    try:
        payload = await asyncio.to_thread(
            _scan_artifacts_sync, db_path, type_norm, limit, offset, q_lower
        )
    except Exception as exc:
        _log.warning("artifacts/gallery scan failed: %s", exc)
        raise HTTPException(status_code=503, detail="artifact read failed")

    return {
        "type": type_norm,
        "results": payload["results"],
        "total": payload["total"],
        "total_capped": payload["total_capped"],
        "offset": offset,
    }


# ---------------------------------------------------------------------------
# Provider / API-key entry (ABH-183) — mobile-side key onboarding for the iOS
# app's provider setup screen. Additive plugin routes only; ZERO stock-core
# edits. Reuses the SAME stock mutators the desktop ``model.save_key`` /
# ``model.disconnect`` RPCs use (hermes_cli.config.save_env_value /
# remove_env_value / set_config_value / is_managed, and the inventory
# ``build_models_payload`` builder), so the credential store and the refreshed
# model list stay in lock-step with the desktop surface. The gateway is the
# source of truth; the client POSTs the key once over the existing TLS
# connection then can clear its transient Keychain copy.
#
# Two tiers mirror the stock flows:
#   Tier A (registered api_key provider): save_env_value(pconfig.api_key_env_vars[0], key)
#   Tier B (custom OpenAI/Anthropic-compatible provider):
#       set_config_value("providers.<name>.{base_url,api_mode,api_key,name}")
#
# SECURITY (non-negotiable):
#   * every route requires the standard dashboard session token AND a device
#     scope (the same belt-and-suspenders as /devices/issue + /approvals/respond);
#   * is_managed() is honoured on every mutator → 4006 read-only for managed
#     installs (parity with stock model.save_key);
#   * OAuth-only providers (auth_type != "api_key") are REJECTED with a 4003
#     "set up on desktop" error — they cannot be provisioned from a key alone
#     (parity with stock model.save_key);
#   * the api_key value is NEVER logged, NEVER echoed in any response body,
#     and NEVER surfaced in the /providers list (which reveals names + the
#     authenticated? boolean only). The audit seam records the EVENT only
#     ("provider <slug> key set/removed by device <Y>");
#   * inputs are validated (slug against PROVIDER_REGISTRY; base_url is a URL;
#     api_mode in the allowed set; provider name is a safe dotted-key segment).
# ---------------------------------------------------------------------------

# auth_type values that CANNOT be provisioned from a raw key on mobile — the
# user must complete them on the desktop (OAuth device code / external OAuth /
# external process / minimax OAuth). Parity with stock model.save_key's
# `auth_type != "api_key"` reject branch, surfaced as the same 4003-class.
_PROVIDER_OAUTH_AUTH_TYPES = frozenset(
    {"oauth_device_code", "oauth_external", "oauth_minimax", "external_process"}
)

# Allowed wire protocols for a Tier B custom provider (matches the stock
# custom-provider transport vocabulary: openai = chat/completions,
# anthropic_messages = Anthropic messages API). Mirrors the accepted values in
# hermes_cli.config._normalize_custom_provider_entry's api_mode handling.
_CUSTOM_PROVIDER_API_MODES = frozenset({"openai", "anthropic_messages"})

# A safe name for the providers.<name>.* dotted config key: alnum + dash +
# underscore only (no dots/brackets that could escape the providers subtree).
_CUSTOM_PROVIDER_NAME_RE = _re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")


def _custom_provider_env_var(name: str) -> str:
    """Derive a stable, collision-resistant env-var NAME for a custom provider's api_key.

    The raw key is written to the secure .env under this name (chmod 0600, never
    printed by ``save_env_value``), and the NAME is stored under
    ``providers.<name>.key_env`` so the runtime resolves the key from the env
    (``runtime_provider.resolve_custom_provider`` reads ``key_env`` →
    ``os.getenv``). Derivation MUST be stable across calls so the POST (set) and
    DELETE (clear) handlers agree on the same var.

    Collision-resistance (ABH-201): names that differ only by separator characters
    (e.g. ``my-co`` vs ``my_co``) both sanitize to ``MY_CO`` and would share the
    same env var under a pure sanitize + suffix scheme. We append a 6-hex-char
    SHA-1 short-hash of the EXACT provider name so each distinct name gets its own
    slot. The hash is deterministic (stable across restarts, depends only on the
    name bytes) and human-readable via the sanitized prefix.

    Examples:
      ``myco``       → ``MYCO_8bad28_API_KEY``
      ``my-co``      → ``MY_CO_6664ff_API_KEY``
      ``my_co``      → ``MY_CO_5e9c77_API_KEY``
      ``Acme-Local`` → ``ACME_LOCAL_adff0c_API_KEY``
    """
    sanitized = _re.sub(r"[^0-9A-Za-z]+", "_", name.strip()).strip("_").upper()
    if not sanitized:
        sanitized = "CUSTOM"
    shorthash = hashlib.sha1(name.encode()).hexdigest()[:6]
    return f"{sanitized}_{shorthash}_API_KEY"


_PROVIDER_KEY_VALIDATION_TIMEOUT_SECONDS = 1.5
_PROVIDER_CREDENTIAL_CONFIG_KEYS = frozenset({"api_key", "key_env"})


def _provider_key_validation_payload(
    validated: Any, detail: str, *, persisted: bool = True
) -> Dict[str, Any]:
    return {
        "validated": validated,
        "validation_detail": detail,
        "persisted": persisted,
    }


def _provider_validation_bases(base_url: str) -> List[str]:
    normalized = (base_url or "").strip().rstrip("/")
    if not normalized:
        return []
    bases = [normalized]
    alternate = normalized[:-3].rstrip("/") if normalized.endswith("/v1") else normalized + "/v1"
    if alternate and alternate not in bases:
        bases.append(alternate)
    return bases


def _validate_provider_key(
    *,
    api_key: str,
    base_url: str,
    api_mode: Optional[str] = None,
    timeout: float = _PROVIDER_KEY_VALIDATION_TIMEOUT_SECONDS,
) -> Dict[str, Any]:
    """Lightweight provider-key liveness check for mobile credential entry.

    The check hits the cheapest auth-gated model-list endpoint with a short
    timeout. Definitive auth rejection (401/403) returns ``validated:false``;
    unreachable/slow/ambiguous failures return ``validated:'skipped'`` so a
    transient network issue never turns the save request into a 500.
    """
    bases = _provider_validation_bases(base_url)
    if not bases:
        return _provider_key_validation_payload(
            "skipped", "key saved; no validation endpoint is configured"
        )

    headers: Dict[str, str] = {"User-Agent": "hermes-mobile-dashboard"}
    if api_key and api_mode == "anthropic_messages":
        headers["x-api-key"] = api_key
        headers["anthropic-version"] = "2023-06-01"
    elif api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    last_error = ""
    for base in bases:
        url = base.rstrip("/") + "/models"
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                try:
                    _json.loads(resp.read().decode() or "{}")
                except Exception:
                    pass
                return _provider_key_validation_payload(
                    True, "provider accepted the API key"
                )
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                return _provider_key_validation_payload(
                    False, f"provider rejected the API key (HTTP {exc.code})"
                )
            last_error = f"HTTP {exc.code}"
            continue
        except Exception as exc:
            # Timeout, DNS, refused connection, TLS, and malformed responses are
            # validation-skipped — the key remains persisted for recovery.
            last_error = str(exc) or exc.__class__.__name__
            continue

    detail = "key saved; provider validation could not be completed"
    if last_error:
        detail += f" ({last_error})"
    return _provider_key_validation_payload("skipped", detail)


def _custom_provider_tuning_entry(entry: Dict[str, Any]) -> Dict[str, Any]:
    """Return non-empty, non-credential config from a custom provider entry."""
    tuning: Dict[str, Any] = {}
    for key, value in entry.items():
        if key in _PROVIDER_CREDENTIAL_CONFIG_KEYS:
            continue
        if value in (None, ""):
            continue
        if isinstance(value, (dict, list, tuple, set)) and not value:
            continue
        tuning[key] = value
    return tuning


def _remove_custom_provider_credentials_from_config(slug: str) -> bool:
    """Delete credentials from providers.<slug>, removing pure-credential husks.

    If the entry has only credential fields, remove the entire providers.<slug>
    subtree so stock provider discovery cannot resurface it as a ghost user-config
    provider. If it carries tuning (base_url/api_mode/model/name/etc.), preserve
    that tuning and remove only credential fields.
    """
    from hermes_cli.config import load_config, save_config

    config = load_config()
    providers = config.get("providers")
    if not isinstance(providers, dict):
        return False
    entry = providers.get(slug)
    if not isinstance(entry, dict):
        return False
    tuning = _custom_provider_tuning_entry(entry)
    if tuning:
        providers[slug] = tuning
    else:
        providers.pop(slug, None)
    save_config(config)
    return True


def _provider_provider_rows() -> List[Dict[str, Any]]:
    """Build the provider universe rows via the stock inventory builder.

    ``picker_hints=True`` is what makes each row carry the
    ``authenticated`` boolean the mobile list surface keys off (same flag the
    TUI frontend + the stock model.save_key refresh use). Imported lazily so
    the module stays importable without the host inventory loaded (tests).
    """
    from hermes_cli.auth import PROVIDER_REGISTRY
    from hermes_cli.inventory import build_models_payload, load_picker_context

    ctx = load_picker_context()
    payload = build_models_payload(
        ctx, picker_hints=True, include_unconfigured=True, max_models=50
    )
    rows = payload.get("providers", []) or []
    return [
        row for row in rows
        if bool(row.get("authenticated"))
        or str(row.get("slug") or "") in PROVIDER_REGISTRY
    ]


def _provider_audit(request: Request, event: str, slug: str) -> None:
    """Audit-log the EVENT only (never the key value).

    Reuses the plugin's existing append-only audit seam (approval_audit.jsonl).
    Records which device/shared credential performed a key mutation and against
    which provider — nothing about the key itself. Best-effort (never raises),
    matching the seam's availability-over-auditability contract.
    """
    try:
        device = _request_device(request)
        device_id = None
        device_name = None
        token_prefix = None
        credential = "shared"
        if isinstance(device, dict) and device.get("device_id"):
            credential = "device"
            device_id = device.get("device_id")
            device_name = device.get("device_name")
            token_prefix = device.get("token_prefix")
        audit_log = _plugin_module("audit_log")
        audit_log.append(
            session_id="",
            session_key="",
            choice="",
            credential=credential,
            device_id=device_id,
            device_name=device_name,
            token_prefix=token_prefix,
            command_preview=f"provider {slug} {event}",
        )
    except Exception:  # pragma: no cover - best-effort, never fatal
        _log.debug("provider-key audit append failed", exc_info=True)


class ToolsetConfigBody(BaseModel):
    key: Optional[str] = None
    value: Optional[str] = None


def _valid_toolset_config_names() -> set[str]:
    from hermes_cli.tools_config import _get_effective_configurable_toolsets

    return {ts_key for ts_key, _, _ in _get_effective_configurable_toolsets()}


def _toolset_config_payload(name: str) -> Tuple[Dict[str, Any], set[str]]:
    """Return the desktop-parity toolset config row and allowed env keys.

    The payload mirrors ``hermes_cli.web_server.get_toolset_config`` but lives
    in the mobile plugin so phone-only clients can inspect which provider keys
    are present. It never includes credential values — only env-var names and
    boolean ``is_set`` states.
    """
    from hermes_cli.config import get_env_value, load_config
    from hermes_cli.tools_config import (
        TOOL_CATEGORIES,
        _is_provider_active,
        _visible_providers,
    )

    config = load_config()
    cat = TOOL_CATEGORIES.get(name)
    providers: List[Dict[str, Any]] = []
    active_provider: Optional[str] = None
    allowed_env_keys: set[str] = set()
    if cat:
        for prov in _visible_providers(cat, config, force_fresh=True):
            env_vars: List[Dict[str, Any]] = []
            for env in prov.get("env_vars", []) or []:
                key = str(env.get("key") or "").strip()
                if not key:
                    continue
                allowed_env_keys.add(key)
                env_vars.append(
                    {
                        "key": key,
                        "prompt": env.get("prompt", key),
                        "url": env.get("url"),
                        "default": env.get("default"),
                        "is_set": bool(get_env_value(key)),
                    }
                )
            is_active = _is_provider_active(prov, config, force_fresh=True)
            if is_active and active_provider is None:
                active_provider = prov["name"]
            providers.append(
                {
                    "name": prov["name"],
                    "badge": prov.get("badge", ""),
                    "tag": prov.get("tag", ""),
                    "env_vars": env_vars,
                    "post_setup": prov.get("post_setup"),
                    "requires_nous_auth": bool(prov.get("requires_nous_auth")),
                    "is_active": is_active,
                }
            )

    return (
        {
            "name": name,
            "has_category": cat is not None,
            "providers": providers,
            "active_provider": active_provider,
        },
        allowed_env_keys,
    )


def _toolset_config_unknown_response(name: str) -> JSONResponse:
    return JSONResponse(
        status_code=400,
        content={"error": f"unknown toolset: {name}", "code": 4002},
    )


@router.get("/toolsets/{name}/config")
async def get_toolset_config(name: str, request: Request) -> Any:
    """Return provider matrix + env-var key status for a toolset config panel."""
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if not _device_has_scope(request, "approve"):
        raise HTTPException(
            status_code=403, detail="Device token lacks approve scope"
        )

    name = (name or "").strip()
    if name not in _valid_toolset_config_names():
        return _toolset_config_unknown_response(name)

    payload, _allowed = _toolset_config_payload(name)
    return payload


@router.put("/toolsets/{name}/config")
async def set_toolset_config(
    name: str, body: ToolsetConfigBody, request: Request
) -> Any:
    """Set or clear an env-var credential for a toolset provider."""
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if not _device_has_scope(request, "approve"):
        raise HTTPException(
            status_code=403, detail="Device token lacks approve scope"
        )

    from hermes_cli.config import is_managed, remove_env_value, save_env_value

    name = (name or "").strip()
    if name not in _valid_toolset_config_names():
        return _toolset_config_unknown_response(name)

    key = (body.key or "").strip()
    if not key:
        return JSONResponse(
            status_code=400, content={"error": "key required", "code": 4001}
        )

    if is_managed():
        return JSONResponse(
            status_code=400,
            content={
                "error": "managed install — credentials are read-only",
                "code": 4006,
            },
        )

    _payload, allowed_env_keys = _toolset_config_payload(name)
    if key not in allowed_env_keys:
        return JSONResponse(
            status_code=400,
            content={"error": f"unknown key for {name}: {key}", "code": 4001},
        )

    value = body.value
    value_text = str(value).strip() if value is not None else ""
    try:
        if not value_text:
            remove_env_value(key)
            os.environ.pop(key, None)
        else:
            save_env_value(key, value_text)
            # Mirror into the live process so the refreshed provider matrix sees
            # the key immediately (parity with set_provider_key below).
            os.environ[key] = value_text
    except ValueError as exc:
        return JSONResponse(
            status_code=400, content={"error": str(exc), "code": 4001}
        )

    refreshed, _allowed = _toolset_config_payload(name)
    return refreshed


@router.get("/providers")
async def list_providers(request: Request) -> Dict[str, Any]:
    """List the provider universe + per-provider authenticated? flag.

    Reveals provider names + slugs + auth_type + an ``authenticated`` boolean
    ONLY. NEVER reveals a key value, env-var contents, or a base_url secret.
    A managed install still lists providers (read-only) — only the mutators
    below honour is_managed(). Auth is the standard dashboard token; a device
    token also needs the ``approve`` scope (the credential-mutation scope).
    """
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if not _device_has_scope(request, "approve"):
        raise HTTPException(
            status_code=403, detail="Device token lacks approve scope"
        )

    try:
        rows = _provider_provider_rows()
    except Exception as exc:  # pragma: no cover - inventory unavailable
        _log.warning("providers/list inventory build failed: %s", exc)
        raise HTTPException(status_code=503, detail="provider list unavailable")

    # Project to the mobile-safe shape: NEVER forward api_key / key_env values
    # or any credential material. ``authenticated`` is the only auth signal.
    safe: List[Dict[str, Any]] = []
    for row in rows:
        slug = row.get("slug") or ""
        if not slug:
            continue
        safe.append(
            {
                "slug": slug,
                "name": row.get("name") or slug,
                "auth_type": row.get("auth_type") or "",
                "is_current": bool(row.get("is_current")),
                "authenticated": bool(row.get("authenticated")),
                "total_models": int(row.get("total_models") or 0),
            }
        )
    return {"providers": safe}


class ProviderKeyBody(BaseModel):
    api_key: str


@router.post("/providers/{slug}/key")
async def set_provider_key(
    slug: str, body: ProviderKeyBody, request: Request
) -> Dict[str, Any]:
    """Tier A — save an API key for a REGISTERED api_key provider.

    Validates ``slug`` is a known PROVIDER_REGISTRY entry with
    ``auth_type == "api_key"`` (else 4003 "set up on desktop" for OAuth-only
    providers — they cannot be provisioned from a key alone). Honours
    is_managed() (4006 read-only for managed installs). Persists via the stock
    ``save_env_value`` + mirrors into os.environ so the refreshed inventory
    sees it immediately (parity with stock model.save_key). Returns the
    refreshed provider row with models populated. NEVER echoes the key.
    """
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if not _device_has_scope(request, "approve"):
        raise HTTPException(
            status_code=403, detail="Device token lacks approve scope"
        )

    slug = (slug or "").strip()
    api_key = (body.api_key or "").strip()
    if not slug:
        return JSONResponse(status_code=400, content={"error": "slug required", "code": 4001})
    if not api_key:
        return JSONResponse(
            status_code=400, content={"error": "api_key required", "code": 4001}
        )

    from hermes_cli.auth import PROVIDER_REGISTRY
    from hermes_cli.config import is_managed, save_env_value

    if is_managed():
        return JSONResponse(
            status_code=400,
            content={
                "error": "managed install — credentials are read-only",
                "code": 4006,
            },
        )

    pconfig = PROVIDER_REGISTRY.get(slug)
    if not pconfig:
        return JSONResponse(
            status_code=400,
            content={"error": f"unknown provider: {slug}", "code": 4002},
        )
    if pconfig.auth_type in _PROVIDER_OAUTH_AUTH_TYPES or pconfig.auth_type != "api_key":
        # OAuth-only / non-key providers cannot be set up from a raw key on
        # mobile — parity with stock model.save_key's 4003 branch.
        return JSONResponse(
            status_code=400,
            content={
                "error": (
                    f"{pconfig.name} uses {pconfig.auth_type} auth — "
                    f"set it up on the desktop"
                ),
                "code": 4003,
            },
        )
    if not pconfig.api_key_env_vars:
        return JSONResponse(
            status_code=400,
            content={
                "error": f"no env var defined for {pconfig.name}",
                "code": 4004,
            },
        )

    env_var = pconfig.api_key_env_vars[0]
    try:
        save_env_value(env_var, api_key)
    except ValueError as exc:
        return JSONResponse(
            status_code=400, content={"error": str(exc), "code": 4001}
        )
    # Mirror into the live process so the refreshed inventory row sees the key
    # (parity with stock model.save_key).
    os.environ[env_var] = api_key

    base_url = ""
    if getattr(pconfig, "base_url_env_var", ""):
        base_url = os.environ.get(pconfig.base_url_env_var, "") or ""
    if not base_url:
        base_url = getattr(pconfig, "inference_base_url", "") or ""
    validation = await asyncio.to_thread(
        _validate_provider_key,
        api_key=api_key,
        base_url=base_url,
        timeout=_PROVIDER_KEY_VALIDATION_TIMEOUT_SECONDS,
    )

    _provider_audit(request, "key set", slug)

    # Refresh via the shared inventory builder; project to the mobile-safe
    # provider shape (NEVER carries the key value).
    provider_data = _refresh_provider_row(slug, fallback_name=pconfig.name)
    provider_data["authenticated"] = validation.get("validated") is not False
    return {"provider": provider_data, **validation}


class CustomProviderBody(BaseModel):
    name: str
    base_url: str
    api_mode: str  # "openai" | "anthropic_messages"
    api_key: str


@router.post("/providers/custom")
async def add_custom_provider(
    body: CustomProviderBody, request: Request
) -> Dict[str, Any]:
    """Tier B — register a custom OpenAI/Anthropic-compatible provider.

    Writes ``providers.<name>.{name,base_url,api_mode,key_env}`` to config.yaml
    via the stock ``set_config_value`` (the same path the desktop ``hermes set``
    uses for a custom provider), and writes the RAW api_key to the secure
    ``~/.hermes/.env`` (chmod 0600, NEVER printed) via ``save_env_value``. The
    runtime resolves the key at request time from ``key_env``
    (``runtime_provider.resolve_custom_provider`` reads ``providers.<name>
    .key_env`` → ``os.getenv``), so the key is usable WITHOUT ever landing in
    config.yaml or a log line. Validates: name is a safe dotted-key segment,
    base_url is a URL, api_mode is in the allowed set, api_key is non-empty.
    Honours is_managed() (4006). NEVER echoes the key.

    SECURITY (ABH-183 review): the previous implementation wrote the raw key
    via ``set_config_value("providers.<name>.api_key", ...)``. That dotted key
    does NOT match stock ``set_config_value``'s ``_API_KEY``-suffix routing
    check (the suffix test needs a leading underscore: ``key.upper().endswith
    (('_API_KEY','_TOKEN'))``), so it fell through to the config.yaml branch
    whose final statement prints ``Set providers.<name>.api_key = <RAW KEY>``
    to stdout — captured at rest by the launchd plists into the dashboard /
    dev-gateway logs. The key_env + save_env_value path below closes that leak.
    """
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if not _device_has_scope(request, "approve"):
        raise HTTPException(
            status_code=403, detail="Device token lacks approve scope"
        )

    from hermes_cli.config import is_managed, save_env_value, set_config_value

    name = (body.name or "").strip()
    base_url = (body.base_url or "").strip()
    api_mode = (body.api_mode or "").strip()
    api_key = (body.api_key or "").strip()

    if not name or not _CUSTOM_PROVIDER_NAME_RE.match(name):
        return JSONResponse(
            status_code=400,
            content={"error": "invalid provider name", "code": 4001},
        )
    if not base_url or not _looks_like_url(base_url):
        return JSONResponse(
            status_code=400, content={"error": "invalid base_url", "code": 4001}
        )
    if api_mode not in _CUSTOM_PROVIDER_API_MODES:
        return JSONResponse(
            status_code=400,
            content={
                "error": "api_mode must be 'openai' or 'anthropic_messages'",
                "code": 4001,
            },
        )
    if not api_key:
        return JSONResponse(
            status_code=400, content={"error": "api_key required", "code": 4001}
        )

    if is_managed():
        return JSONResponse(
            status_code=400,
            content={
                "error": "managed install — credentials are read-only",
                "code": 4006,
            },
        )

    # Persist the custom-provider subtree via the stock config mutator (the
    # same path the desktop ``hermes set providers.<name>.*`` uses), but route
    # the RAW api_key to the secure .env (chmod 0600, never printed) and store
    # ONLY the env-var NAME under ``providers.<name>.key_env``. The runtime
    # resolves the key from key_env at request time
    # (runtime_provider.resolve_custom_provider: ``key_env = entry.get(
    # "key_env")`` → ``os.getenv(key_env)``), so the key is usable WITHOUT a
    # raw secret ever touching config.yaml or a log line. This mirrors the
    # hygiene of the desktop's key_env-backed custom providers.
    env_var = _custom_provider_env_var(name)
    try:
        save_env_value(env_var, api_key)
        set_config_value(f"providers.{name}.name", name)
        set_config_value(f"providers.{name}.base_url", base_url)
        set_config_value(f"providers.{name}.api_mode", api_mode)
        set_config_value(f"providers.{name}.key_env", env_var)
    except ValueError as exc:
        return JSONResponse(
            status_code=400, content={"error": str(exc), "code": 4001}
        )

    os.environ[env_var] = api_key
    validation = await asyncio.to_thread(
        _validate_provider_key,
        api_key=api_key,
        base_url=base_url,
        api_mode=api_mode,
        timeout=_PROVIDER_KEY_VALIDATION_TIMEOUT_SECONDS,
    )

    _provider_audit(request, "custom provider added", name)

    provider_data = _refresh_provider_row(name, fallback_name=name)
    provider_data["authenticated"] = validation.get("validated") is not False
    return {"provider": provider_data, **validation}


@router.delete("/providers/{slug}/key")
async def remove_provider_key(
    slug: str, request: Request
) -> Dict[str, Any]:
    """Remove credentials for a provider (parity with stock model.disconnect).

    For a registered api_key provider: ``remove_env_value`` on each of its
    api_key_env_vars. For a CUSTOM provider (not in PROVIDER_REGISTRY, or a
    registered slug that also has a ``providers.<slug>`` config entry): the key
    was persisted under ``providers.<name>.key_env`` (POST /providers/custom)
    pointing at a secure .env var — so in addition to ``clear_provider_auth`` we
    ALSO clear that persisted state: remove the .env var, blank the inline
    ``api_key``, and drop ``key_env`` from config.yaml. Without this, the key
    would persist in .env + config.yaml while the route returned
    ``disconnected:true``.

    BUG 3 fix: custom-clear is now also triggered when slug IS in PROVIDER_REGISTRY
    but also has a ``providers.<slug>`` config entry — e.g. a local proxy named
    'anthropic'. Registry membership alone no longer suppresses the config-clear.

    BUG 4 fix: slug is validated against _CUSTOM_PROVIDER_NAME_RE before any
    operation (reject 4001 on dotted/invalid slugs). In the custom-clear branch,
    config is read first; if no ``providers.<slug>`` entry exists, the handler
    does NOT write any config entries and returns 4005 instead.

    Honours is_managed() (4006). Returns the provider's slug + name + a
    ``disconnected`` flag. NEVER echoes a key.
    """
    if not _has_dashboard_api_auth(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if not _device_has_scope(request, "approve"):
        raise HTTPException(
            status_code=403, detail="Device token lacks approve scope"
        )

    from hermes_cli.auth import PROVIDER_REGISTRY, clear_provider_auth
    from hermes_cli.config import (
        is_managed,
        load_config_readonly,
        remove_env_value,
    )

    slug = (slug or "").strip()
    if not slug:
        return JSONResponse(
            status_code=400, content={"error": "slug required", "code": 4001}
        )

    # BUG 4 fix (part 1): reject slugs that contain characters that could escape
    # the providers.<slug>.* config subtree (e.g. dots that create junk nested
    # trees, or other chars outside the safe name alphabet). Dotted slugs arrive
    # as multi-segment URL paths, which FastAPI resolves before the handler, but
    # we validate defensively here since config keys are built from this value.
    if not _CUSTOM_PROVIDER_NAME_RE.match(slug):
        return JSONResponse(
            status_code=400,
            content={"error": f"invalid provider slug: {slug!r}", "code": 4001},
        )

    if is_managed():
        return JSONResponse(
            status_code=400,
            content={
                "error": "managed install — credentials are read-only",
                "code": 4006,
            },
        )

    pconfig = PROVIDER_REGISTRY.get(slug)
    cleared_env = False
    cleared_config = False
    cleared_auth = False

    if pconfig and pconfig.api_key_env_vars:
        for ev in pconfig.api_key_env_vars:
            try:
                if remove_env_value(ev):
                    cleared_env = True
            except ValueError:
                continue

    # BUG 3 fix: run the custom-clear block whenever a providers.<slug> config
    # entry exists — NOT only when the slug is absent from PROVIDER_REGISTRY.
    # A custom provider named 'anthropic' (which IS in the registry) would
    # otherwise skip the config/env clear and return 200 disconnected:true
    # while its raw key persisted in .env + config.yaml.
    #
    # BUG 4 fix (part 2): read config BEFORE writing anything. Only proceed with
    # the clear when a providers.<slug> entry actually exists. If absent, do not
    # write bogus config entries and do not set cleared_config = True (which
    # would cause a never-created slug to get a spurious 200 disconnected:true).
    try:
        config = load_config_readonly()
    except Exception:
        config = {}
    _providers_cfg = config.get("providers") or {}
    _entry = _providers_cfg.get(slug)
    # BUG5 fix: restrict the custom-clear branch to entries that are actually
    # CUSTOM-PROVIDER CREDENTIAL entries — i.e. they have an ``api_key`` or
    # ``key_env`` field (the markers POST /providers/custom writes). A registered
    # provider can legitimately have a providers.<slug> tuning-only entry (e.g.
    # a ``base_url`` or ``model`` override) without any credential fields. Firing
    # the custom-clear on such a tuning-only entry would inject bogus empty
    # ``api_key``/``key_env`` keys and try to remove a phantom env var.
    has_custom_entry = bool(
        _entry and ("api_key" in _entry or "key_env" in _entry)
    )

    if has_custom_entry:
        # A custom provider (POST /providers/custom) persists its key under
        # ``providers.<slug>.key_env`` (an env-var NAME) with the raw key in the
        # secure .env. clear_provider_auth only mutates the auth_store JSON —
        # it never touches config.yaml or the .env — so we clear the persisted
        # state explicitly here. The key MUST actually be gone after a 200.
        #
        # Backward-compat (ABH-201): ``_custom_provider_env_var`` used to emit a
        # hash-less name (e.g. ``MY_CO_API_KEY``); the collision fix appended a
        # 6-hex SHA-1 short-hash (``MY_CO_6664ff_API_KEY``). Providers created
        # BEFORE the fix therefore carry the OLD env-var NAME in their stored
        # ``key_env`` AND have their raw key sitting under that OLD name in .env.
        # Re-deriving the name here would compute the NEW (hashed) var and
        # remove a non-existent entry while the legacy key leaked in .env. So we
        # prefer the STORED ``key_env`` when present (covers both legacy and
        # current schemes) and only fall back to re-derivation for an entry
        # that has an inline ``api_key`` but no recorded env-var name.
        stored_key_env = _entry.get("key_env") if isinstance(_entry, dict) else None
        env_var = stored_key_env or _custom_provider_env_var(slug)
        try:
            if remove_env_value(env_var):
                cleared_env = True
        except ValueError:
            pass
        # Remove credential fields from config.yaml. Pure credential-only custom
        # entries are deleted entirely so stock model discovery cannot resurface
        # an empty providers.<slug> husk as a ghost user-config row. Entries with
        # non-credential tuning keep that tuning and lose only api_key/key_env.
        try:
            cleared_config = _remove_custom_provider_credentials_from_config(slug)
        except ValueError:
            pass

    # Clear OAuth / credential pool state + custom-provider credentials. This
    # is a no-op when the slug has no such state.
    try:
        cleared_auth = bool(clear_provider_auth(slug))
    except Exception:  # pragma: no cover - defensive, never fatal
        cleared_auth = False

    if not cleared_env and not cleared_config and not cleared_auth:
        return JSONResponse(
            status_code=400,
            content={"error": f"no credentials found for {slug}", "code": 4005},
        )

    _provider_audit(request, "key removed", slug)

    provider_name = pconfig.name if pconfig else slug
    return {
        "slug": slug,
        "name": provider_name,
        "disconnected": True,
    }


# ---------------------------------------------------------------------------
# Provider/key helpers (pure — unit-testable without a gateway).
# ---------------------------------------------------------------------------


def _looks_like_url(value: str) -> bool:
    """Light URL validation for a custom-provider base_url.

    Accepts ``http://`` and ``https://`` URLs with a non-empty host. Deliberately
    permissive (no DNS/TLS probe) so a self-hosted LAN endpoint or a localhost
    dev gateway passes — we are validating SHAPE, not reachability. Rejects
    ``file://``, bare hosts, and anything with whitespace.
    """
    if not isinstance(value, str) or not value:
        return False
    lowered = value.lower()
    if not (lowered.startswith("http://") or lowered.startswith("https://")):
        return False
    if any(ch.isspace() for ch in value):
        return False
    # Strip the scheme, then require a non-empty host before the next '/'.
    # A bare ``localhost`` (no dot) is a valid host for a dev gateway, as is an
    # IPv4 literal — so require a non-empty host that either contains a dot or
    # is exactly ``localhost``. The previous expression reduced to ``bool(host)``
    # by operator precedence (the dot-check was dead code); this is the intended
    # shape and still admits https://api.openai.com, http://localhost:8080, and
    # https://192.168.1.5/v1 while rejecting scheme-only garbage like "https://".
    rest = value.split("://", 1)[1]
    host = rest.split("/", 1)[0]
    if not host:
        return False
    # Strip an optional port before the dot/IP checks.
    host_no_port = host.rsplit(":", 1)[0] if ":" in host else host
    return "." in host_no_port or host_no_port == "localhost"


def _refresh_provider_row(slug: str, *, fallback_name: str = "") -> Dict[str, Any]:
    """Return the mobile-safe provider row for ``slug`` after a mutation.

    Rebuilds the inventory and projects to the same safe shape as
    ``list_providers`` (NEVER a key value). Falls back to a minimal row when the
    slug does not surface in the inventory (the key was still persisted — parity
    with stock model.save_key's "still return success" branch).
    """
    try:
        rows = _provider_provider_rows()
    except Exception:  # pragma: no cover - inventory unavailable
        rows = []
    for row in rows:
        if row.get("slug") == slug:
            if not row.get("authenticated"):
                continue
            return {
                "slug": row.get("slug") or slug,
                "name": row.get("name") or fallback_name or slug,
                "auth_type": row.get("auth_type") or "",
                "is_current": bool(row.get("is_current")),
                "authenticated": bool(row.get("authenticated")),
                "total_models": int(row.get("total_models") or 0),
                "models": row.get("models") or [],
            }
    return {
        "slug": slug,
        "name": fallback_name or slug,
        "auth_type": "",
        "is_current": False,
        "authenticated": True,
        "total_models": 0,
        "models": [],
    }
