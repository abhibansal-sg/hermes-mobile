from __future__ import annotations

import os
import stat


def read_secure_file(path: str, *, label: str, max_bytes: int) -> bytes:
    """Read a small secret from one already-validated file descriptor.

    Secret files are deliberately stricter than ordinary configuration files:
    links and non-regular files are rejected, and no group or other permission
    bits may be present.  Reading through the opened descriptor avoids a
    stat-then-open race.
    """

    if not path or max_bytes <= 0:
        raise ValueError(f"{label} could not be securely read")
    no_follow = getattr(os, "O_NOFOLLOW", None)
    if no_follow is None:
        raise ValueError(f"{label} requires O_NOFOLLOW support")
    flags = os.O_RDONLY | no_follow | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ValueError(f"{label} could not be securely read") from exc

    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"{label} must be a regular file")
        if info.st_nlink != 1:
            raise ValueError(f"{label} must have exactly one hard link")
        if stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError(f"{label} must have owner-only permissions")
        if info.st_size > max_bytes:
            raise ValueError(f"{label} exceeds its size limit")

        chunks: list[bytes] = []
        remaining = max_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(remaining, 16 * 1024))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        value = b"".join(chunks)
        if len(value) > max_bytes:
            raise ValueError(f"{label} exceeds its size limit")
        return value
    finally:
        os.close(descriptor)


def read_secure_text(path: str, *, label: str, max_bytes: int) -> str:
    try:
        return read_secure_file(path, label=label, max_bytes=max_bytes).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"{label} must be UTF-8") from exc
