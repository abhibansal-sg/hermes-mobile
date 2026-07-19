"""Canonical origin validation for HRP/2 transport services."""

from __future__ import annotations

import ipaddress
import re
from urllib.parse import urlsplit, urlunsplit


_DNS_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")


def canonical_service_origin(
    value: str,
    *,
    label: str,
    allow_insecure_local: bool = False,
) -> str:
    """Return one credential-free HTTP(S) origin or fail closed."""

    if not isinstance(value, str):
        raise ValueError(f"{label} must be a string")
    raw = value.strip()
    if not raw or any(ord(character) < 0x20 for character in raw):
        raise ValueError(f"{label} must be a non-empty HTTP(S) origin")
    parsed = urlsplit(raw)
    scheme = parsed.scheme.lower()
    if scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError(f"{label} must be an absolute HTTP(S) origin")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError(f"{label} must not contain credentials")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise ValueError(f"{label} must not contain a path, query, or fragment")
    host = parsed.hostname
    if host is None or "%" in host:
        raise ValueError(f"{label} host is invalid")
    try:
        port = parsed.port
    except ValueError as exc:
        raise ValueError(f"{label} port is invalid") from exc

    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        try:
            canonical_host = host.encode("idna").decode("ascii").lower()
        except UnicodeError as exc:
            raise ValueError(f"{label} host is invalid") from exc
        if len(canonical_host) > 253 or any(
            not _DNS_LABEL.fullmatch(part) for part in canonical_host.split(".")
        ):
            raise ValueError(f"{label} host is invalid")
        is_loopback = canonical_host == "localhost"
        netloc_host = canonical_host
    else:
        canonical_host = address.compressed.lower()
        is_loopback = address.is_loopback
        netloc_host = f"[{canonical_host}]" if address.version == 6 else canonical_host

    if scheme == "http" and not (allow_insecure_local and is_loopback):
        raise ValueError(f"plaintext {label} requires explicit loopback-only opt-in")
    if port is not None and not (
        (scheme == "https" and port == 443) or (scheme == "http" and port == 80)
    ):
        netloc_host = f"{netloc_host}:{port}"
    return urlunsplit((scheme, netloc_host, "", "", ""))


__all__ = ["canonical_service_origin"]
