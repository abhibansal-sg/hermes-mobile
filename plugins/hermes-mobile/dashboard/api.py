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

import importlib
import importlib.util
import logging
import os
import secrets
import stat
import sys
import time
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

    # Normalise offset.
    try:
        offset = int(offset)
    except (TypeError, ValueError):
        offset = 0
    offset = max(0, offset)

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
