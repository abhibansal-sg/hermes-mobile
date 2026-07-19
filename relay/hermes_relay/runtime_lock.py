"""Exclusive process ownership for one HRP/2 Relay state directory."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .secure_files import open_secure_lock_file


class RelayRuntimeAlreadyRunning(RuntimeError):
    """Another long-lived HRP/2 runtime owns this state directory."""


class RelayRuntimeLock:
    """Portable non-blocking lock held for a complete runtime or lifecycle edit.

    The lock is a sibling of the state directory rather than a child of it.
    Purge can therefore retain exclusive ownership while removing state on
    every supported platform.  Canonicalizing the path also ensures symlink
    aliases cannot acquire independent locks for the same SQLite database.
    """

    def __init__(self, state_directory: Path) -> None:
        self.state_directory = Path(state_directory).expanduser().resolve(strict=False)
        self.path = self.state_directory.with_name(
            f".{self.state_directory.name}.runtime.lock"
        )
        self._handle: Any = None
        self._kind: str | None = None

    def __enter__(self) -> "RelayRuntimeLock":
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            self._handle = open_secure_lock_file(self.path)
            if os.name == "nt":
                import msvcrt

                self._handle.seek(0)
                if self._handle.read(1) == b"":
                    self._handle.write(b"0")
                    self._handle.flush()
                self._handle.seek(0)
                msvcrt.locking(self._handle.fileno(), msvcrt.LK_NBLCK, 1)
                self._kind = "msvcrt"
            elif os.name == "posix":
                import fcntl

                fcntl.flock(
                    self._handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB
                )
                self._kind = "fcntl"
            else:
                raise RelayRuntimeAlreadyRunning(
                    "exclusive HRP/2 runtime locking is unavailable"
                )
        except RelayRuntimeAlreadyRunning:
            if self._handle is not None:
                self._handle.close()
            self._handle = None
            raise
        except (BlockingIOError, OSError) as exc:
            if self._handle is not None:
                self._handle.close()
            self._handle = None
            raise RelayRuntimeAlreadyRunning(
                "another HRP/2 Relay process already owns this state directory"
            ) from exc
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        handle, self._handle = self._handle, None
        if handle is None:
            return
        try:
            if self._kind == "msvcrt":
                import msvcrt

                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            elif self._kind == "fcntl":
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            self._kind = None
            handle.close()


# Private compatibility alias retained for existing imports and focused tests.
_RelayRuntimeLock = RelayRuntimeLock


__all__ = [
    "RelayRuntimeAlreadyRunning",
    "RelayRuntimeLock",
    "_RelayRuntimeLock",
]
