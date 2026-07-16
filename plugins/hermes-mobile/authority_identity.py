"""Stable installation/profile/database identity for hermes-mobile contracts.

This module owns only infrastructure metadata. It never reads transcript rows,
mutates model context, or participates in prompt construction.
"""

from __future__ import annotations

import json
import os
import secrets
import stat
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable

from hermes_cli.profiles import ensure_profile_id, read_profile_meta
from hermes_state import SessionDB, StateAuthorityIdentityError


SCHEMA_VERSION = 1


class AuthorityIdentityError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class ProfileAuthority:
    profile_id: str
    profile_name: str
    authority_epoch: str


@dataclass(frozen=True, slots=True)
class AuthorityContext:
    gateway_id: str
    profiles: tuple[ProfileAuthority, ...]


def installation_root(home: Path) -> Path:
    home = Path(home)
    return home.parent.parent if home.parent.name == "profiles" else home


def _registry_path(root: Path) -> Path:
    return root / "mobile" / "authority-identity-v1.json"


@contextmanager
def _registry_lock(root: Path):
    path = root / "mobile" / ".authority-identity.lock"
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    handle = path.open("a+b")
    try:
        if os.name == "nt":
            import msvcrt

            if path.stat().st_size == 0:
                handle.write(b" ")
                handle.flush()
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield
    finally:
        try:
            if os.name == "nt":
                import msvcrt

                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            handle.close()


def _new_id(prefix: str) -> str:
    return prefix + secrets.token_urlsafe(16)


def _read_registry(path: Path) -> dict:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {
            "schema_version": SCHEMA_VERSION,
            "gateway_id": _new_id("gw_"),
            "profiles": {},
        }
    except Exception as exc:
        raise AuthorityIdentityError("invalid installation identity registry") from exc
    if (
        not isinstance(payload, dict)
        or payload.get("schema_version") != SCHEMA_VERSION
        or not isinstance(payload.get("gateway_id"), str)
        or not payload["gateway_id"].startswith("gw_")
        or not isinstance(payload.get("profiles"), dict)
    ):
        raise AuthorityIdentityError("invalid installation identity registry")
    return payload


def _write_registry(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp")
    fd = os.open(
        temp,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        stat.S_IRUSR | stat.S_IWUSR,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            temp.unlink(missing_ok=True)
        except OSError:
            pass


def ensure_profile_authority(profile_name: str, home: Path) -> AuthorityContext:
    """Establish one writable profile and reconcile it with the registry."""
    home = Path(home)
    root = installation_root(home)
    with _registry_lock(root):
        registry = _read_registry(_registry_path(root))
        profile_id = ensure_profile_id(home)
        db = SessionDB(home / "state.db")
        try:
            identity = db.get_or_create_authority_identity(
                expected_profile_id=profile_id
            )
            registered = registry["profiles"].get(profile_id)
            if registered is not None and registered.get("authority_epoch") != identity.authority_epoch:
                # Registry/DB disagreement means the DB was copied, restored, or
                # a crash exposed an unregistered epoch. Rotate before serving.
                identity = db.rotate_authority_epoch(expected_profile_id=profile_id)
            registry["profiles"][profile_id] = {
                "last_known_name": profile_name,
                "authority_epoch": identity.authority_epoch,
            }
            _write_registry(_registry_path(root), registry)
        finally:
            db.close()
    descriptor = ProfileAuthority(
        profile_id=profile_id,
        profile_name=profile_name,
        authority_epoch=identity.authority_epoch,
    )
    return AuthorityContext(registry["gateway_id"], (descriptor,))


def read_profile_authorities(
    homes: Iterable[tuple[str, Path]],
) -> AuthorityContext:
    """Read established identities without mutating profile DBs or metadata."""
    homes = tuple((name, Path(home)) for name, home in homes)
    if not homes:
        raise AuthorityIdentityError("no profiles in requested authority scope")
    root = installation_root(homes[0][1])
    with _registry_lock(root):
        registry = _read_registry(_registry_path(root))
        descriptors: list[ProfileAuthority] = []
        seen: set[str] = set()
        for profile_name, home in homes:
            profile_id = read_profile_meta(home).get("profile_id")
            if not profile_id:
                raise AuthorityIdentityError(
                    f"identity_pending for profile {profile_name}"
                )
            if profile_id in seen:
                raise AuthorityIdentityError("duplicate profile_id")
            seen.add(profile_id)
            db = SessionDB(home / "state.db", read_only=True)
            try:
                identity = db.read_authority_identity()
            finally:
                db.close()
            if identity is None:
                raise AuthorityIdentityError(
                    f"identity_pending for profile {profile_name}"
                )
            if identity.profile_id != profile_id:
                raise AuthorityIdentityError("profile/database identity mismatch")
            registered = registry["profiles"].get(profile_id)
            if not registered or registered.get("authority_epoch") != identity.authority_epoch:
                raise AuthorityIdentityError("registry/database identity mismatch")
            descriptors.append(
                ProfileAuthority(profile_id, profile_name, identity.authority_epoch)
            )
    descriptors.sort(key=lambda item: item.profile_id)
    return AuthorityContext(registry["gateway_id"], tuple(descriptors))


def context_payload(context: AuthorityContext) -> dict:
    return {
        "gateway_id": context.gateway_id,
        "profile_authorities": [asdict(item) for item in context.profiles],
    }
