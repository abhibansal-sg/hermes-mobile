"""Race-resistant helpers for local relay credential and lock files.

The HRP/2 service is commonly launched by a supervisor. Paths therefore stay
operator-controlled, but an already-created symlink or hard link must never be
allowed to redirect a secret read or lock-file permission change.
"""

from __future__ import annotations

import os
import stat
from pathlib import Path
from typing import BinaryIO


def _secure_open_flags(flags: int) -> int:
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_BINARY", 0)
    return flags


def _validate_open_file(
    descriptor: int,
    *,
    path: Path,
    owner_only: bool,
) -> os.stat_result:
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode):
        raise PermissionError(f"path is not a regular file: {path}")
    if info.st_nlink != 1:
        raise PermissionError(f"file must have exactly one link: {path}")
    if os.name == "posix":
        if info.st_uid != os.geteuid():
            raise PermissionError(f"file must be owned by the service user: {path}")
        if owner_only and stat.S_IMODE(info.st_mode) & 0o077:
            raise PermissionError(f"file must be mode 0600 or stricter: {path}")
    return info


def open_secure_lock_file(path: Path) -> BinaryIO:
    """Open or create a single-link, owner-only regular lock file."""

    lock_path = Path(path)
    descriptor = os.open(
        lock_path,
        _secure_open_flags(os.O_RDWR | os.O_CREAT),
        0o600,
    )
    try:
        _validate_open_file(descriptor, path=lock_path, owner_only=False)
        if os.name == "posix":
            os.fchmod(descriptor, 0o600)
            _validate_open_file(descriptor, path=lock_path, owner_only=True)
        return os.fdopen(descriptor, "r+b", buffering=0)
    except Exception:
        os.close(descriptor)
        raise


def read_secure_text_file(
    path: Path,
    *,
    owner_only: bool,
    maximum_bytes: int = 65_536,
) -> str:
    """Read UTF-8 from the exact regular file validated after opening it."""

    if maximum_bytes < 1:
        raise ValueError("maximum_bytes must be positive")
    token_path = Path(path).expanduser()
    descriptor = os.open(token_path, _secure_open_flags(os.O_RDONLY))
    try:
        _validate_open_file(descriptor, path=token_path, owner_only=owner_only)
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(remaining, 8192))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if len(raw) > maximum_bytes:
            raise ValueError(f"file exceeds {maximum_bytes} bytes: {token_path}")
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError(f"file is not valid UTF-8: {token_path}") from exc
    finally:
        os.close(descriptor)


__all__ = ["open_secure_lock_file", "read_secure_text_file"]
