"""Approval audit log (hermes-mobile W3a) — bounded 0600 JSONL.

Records WHICH device (or the shared token) resolved each gateway approval, so
the iOS Devices panel can surface a read-only audit trail. One JSON object per
line at ``<HERMES_HOME>/approval_audit.jsonl``.

Security posture (mirrors device_tokens + ws_tickets):
- A JSONL append starts with chmod-on-create (0600) + append-under-lock. When
  the file exceeds ``_MAX_LOG_BYTES``, the oldest complete records are pruned
  under the same lock via tmp+replace so disk and read memory stay bounded.
- A record NEVER stores a full token — only a stable ``device_id`` and an
  8-char ``token_prefix``. ``command_preview`` is truncated to 120 chars.
- The write is BEST-EFFORT: ``append`` swallows + logs (truncated) any error so
  an approval ALWAYS resolves even if the audit log can't be written
  (availability > auditability for the live agent loop).
"""

from __future__ import annotations

import json
import logging
import os
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

_log = logging.getLogger(__name__)

# Serialise appends so concurrent resolvers never interleave a half-written line.
_audit_lock = threading.Lock()

_PREVIEW_MAX = 120
_DEFAULT_LIMIT = 100
_MAX_LIMIT = 500
_TOKEN_PREFIX_LEN = 8
_MAX_LOG_BYTES = 1024 * 1024


def _audit_log_path() -> Path:
    """Resolve the audit-log path, honouring HERMES_HOME (mirrors the registry
    path helpers; falls back to ~/.hermes for import-in-isolation)."""
    try:
        from hermes_cli.config import get_hermes_home

        return get_hermes_home() / "approval_audit.jsonl"
    except Exception:  # pragma: no cover - defensive fallback
        return Path(os.path.expanduser("~/.hermes")) / "approval_audit.jsonl"


def _truncate_preview(text: Any) -> str:
    """Coerce + truncate a command/description to ≤120 chars for the preview."""
    if not isinstance(text, str):
        return ""
    text = " ".join(text.split())  # collapse newlines/whitespace (no raw dumps)
    return text[:_PREVIEW_MAX]


def _build_command_preview(data: Any) -> str:
    """Derive ``command_preview`` from an _ApprovalEntry.data dict.

    Prefers ``description`` over ``command`` when the description is present —
    a command may carry a secret the preview shouldn't capture, whereas the
    description is a human summary. Falls back to ``command`` then ``""``.
    """
    if not isinstance(data, dict):
        return ""
    desc = data.get("description")
    if isinstance(desc, str) and desc.strip():
        return _truncate_preview(desc)
    return _truncate_preview(data.get("command"))


def _tail_bytes(path: Path, max_bytes: int) -> bytes:
    """Read at most ``max_bytes`` from the end of ``path`` on line boundaries."""
    max_bytes = max(1, int(max_bytes))
    size = path.stat().st_size
    start = max(0, size - max_bytes)
    with path.open("rb") as fh:
        fh.seek(start)
        data = fh.read(max_bytes)
    if start > 0:
        first_newline = data.find(b"\n")
        if first_newline == -1:
            return b""
        data = data[first_newline + 1 :]
    return data


def _prune_to_max_bytes(path: Path) -> None:
    """Keep the newest complete JSONL records within ``_MAX_LOG_BYTES``."""
    tmp: Optional[Path] = None
    try:
        if path.stat().st_size <= _MAX_LOG_BYTES:
            return
        data = _tail_bytes(path, _MAX_LOG_BYTES)
        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
        )
        tmp = Path(tmp_name)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        try:
            os.chmod(tmp, 0o600)
        except OSError:  # pragma: no cover - non-POSIX / quirk
            pass
        os.replace(tmp, path)
        try:
            os.chmod(path, 0o600)
        except OSError:  # pragma: no cover - non-POSIX / quirk
            pass
    except Exception as exc:  # pragma: no cover - best-effort retention
        if tmp is not None:
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass
        _log.warning("could not prune approval audit log: %s", exc)


def append(
    *,
    session_id: str = "",
    session_key: str = "",
    choice: str = "",
    resolve_all: bool = False,
    credential: str = "shared",
    device_id: Optional[str] = None,
    device_name: Optional[str] = None,
    token_prefix: Optional[str] = None,
    command_preview: str = "",
) -> bool:
    """Append ONE audit record (best-effort). Returns True on success, False on
    any failure (caller treats failure as non-fatal — the approval still
    resolves). NEVER raises."""
    rec: Dict[str, Any] = {
        "ts": time.time(),
        "session_id": session_id or "",
        "session_key": session_key or "",
        "choice": choice or "",
        "resolve_all": bool(resolve_all),
        "credential": credential or "shared",
        "device_id": device_id,
        "device_name": device_name,
        # Defensive: only ever an 8-char prefix, never a full token.
        "token_prefix": (token_prefix[:_TOKEN_PREFIX_LEN] if token_prefix else None),
        "command_preview": (command_preview or "")[:_PREVIEW_MAX],
    }
    path = _audit_log_path()
    try:
        with _audit_lock:
            path.parent.mkdir(parents=True, exist_ok=True)
            is_new = not path.exists()
            fd = os.open(
                path,
                os.O_WRONLY | os.O_CREAT | os.O_APPEND,
                0o600,
            )
            with os.fdopen(fd, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec) + "\n")
                fh.flush()
            if is_new:
                # First-create chmod — append mode can't use tmp+replace.
                try:
                    os.chmod(path, 0o600)
                except OSError:  # pragma: no cover - non-POSIX / quirk
                    pass
            _prune_to_max_bytes(path)
        return True
    except Exception as exc:  # pragma: no cover - best-effort, never fatal
        _log.warning("could not append approval audit record: %s", exc)
        return False


def read(
    limit: int = _DEFAULT_LIMIT, session_id: Optional[str] = None
) -> List[Dict[str, Any]]:
    """Return up to ``limit`` (clamped to [1, 500]) audit records, most-recent
    first, optionally filtered by ``session_id``. A missing/corrupt file → []
    (never raises). Malformed lines are skipped."""
    try:
        limit = int(limit)
    except (TypeError, ValueError):
        limit = _DEFAULT_LIMIT
    limit = max(1, min(limit, _MAX_LIMIT))

    path = _audit_log_path()
    try:
        with _audit_lock:
            raw = _tail_bytes(path, _MAX_LOG_BYTES).decode(
                "utf-8", errors="ignore"
            )
    except (FileNotFoundError, OSError):
        return []

    out: List[Dict[str, Any]] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue  # skip a corrupt line, keep reading
        if not isinstance(rec, dict):
            continue
        if session_id is not None and rec.get("session_id") != session_id:
            continue
        out.append(rec)

    # Most-recent first: the file is append-order (oldest→newest), so reverse
    # the (already session-filtered) list and take the tail window.
    out.reverse()
    return out[:limit]
