"""Platform credential protection for durable HRP/2 secrets.

The database stores either an opaque Keychain handle, a Windows DPAPI blob, a
keyring handle, or an explicitly labelled file-permissions fallback.  Callers
can surface :attr:`mode`; fallback is never misrepresented as OS-backed key
protection.
"""

from __future__ import annotations

import base64
import os
import platform
import secrets
from typing import Protocol


class CredentialProtectionError(RuntimeError):
    pass


def _delete_keyring_password(
    keyring: object, *, service: str, account: str, backend_name: str
) -> None:
    """Delete one keyring entry without treating absence as a backend failure.

    ``keyring`` backends do not expose a portable not-found exception: several
    raise ``PasswordDeleteError`` for both an absent item and a real backend
    failure.  Read-before-delete plus a post-error read distinguishes those
    cases.  A missing item (including a delete which committed before raising)
    is success; an entry which remains, or a failed read, is surfaced.
    """

    get_password = getattr(keyring, "get_password")
    delete_password = getattr(keyring, "delete_password")
    try:
        if get_password(service, account) is None:
            return
    except Exception as exc:
        raise CredentialProtectionError(
            f"{backend_name} read before delete failed"
        ) from exc
    try:
        delete_password(service, account)
    except Exception as exc:
        try:
            if get_password(service, account) is None:
                return
        except Exception as read_exc:
            raise CredentialProtectionError(
                f"{backend_name} delete verification failed"
            ) from read_exc
        raise CredentialProtectionError(f"{backend_name} delete failed") from exc


class CredentialProtector(Protocol):
    mode: str

    def protect(self, label: str, secret: bytes) -> bytes: ...
    def reveal(self, wrapped: bytes) -> bytes: ...
    def delete(self, wrapped: bytes) -> None: ...


class FilePermissionFallbackProtector:
    """Explicit last-resort wrapper relying on the hardened 0700/0600 state."""

    mode = "file-permissions-fallback"
    _prefix = b"plain-v1:"

    def protect(self, label: str, secret: bytes) -> bytes:
        if not isinstance(secret, bytes) or not secret:
            raise CredentialProtectionError("secret must be non-empty bytes")
        return self._prefix + secret

    def reveal(self, wrapped: bytes) -> bytes:
        if not wrapped.startswith(self._prefix):
            raise CredentialProtectionError("not a fallback-protected value")
        return wrapped[len(self._prefix) :]

    def delete(self, wrapped: bytes) -> None:
        return None


class MacOSKeychainProtector:
    """macOS Keychain through the vetted Python keyring Security backend.

    Secrets are passed in-process to the backend and never placed in argv.
    """

    mode = "macos-keychain-keyring"
    _prefix = b"keychain-v1:"

    def __init__(self, service: str = "ai.hermes.mobile-relay") -> None:
        self.service = service
        try:
            import keyring
        except ImportError as exc:
            raise CredentialProtectionError(
                "macOS keyring backend unavailable"
            ) from exc
        backend = keyring.get_keyring()
        if getattr(backend, "priority", 0) <= 0:
            raise CredentialProtectionError("no usable macOS Keychain backend")
        self._keyring = keyring

    def protect(self, label: str, secret: bytes) -> bytes:
        account = f"{label}:{secrets.token_urlsafe(12)}"
        encoded = base64.urlsafe_b64encode(secret).decode("ascii")
        try:
            self._keyring.set_password(self.service, account, encoded)
        except Exception as exc:
            raise CredentialProtectionError("macOS Keychain write failed") from exc
        return self._prefix + account.encode("utf-8")

    def reveal(self, wrapped: bytes) -> bytes:
        account = self._account(wrapped)
        value = self._keyring.get_password(self.service, account)
        if value is None:
            raise CredentialProtectionError("macOS Keychain read failed")
        try:
            return base64.urlsafe_b64decode(value.encode("ascii"))
        except Exception as exc:
            raise CredentialProtectionError("macOS Keychain value is invalid") from exc

    def delete(self, wrapped: bytes) -> None:
        account = self._account(wrapped)
        _delete_keyring_password(
            self._keyring,
            service=self.service,
            account=account,
            backend_name="macOS Keychain",
        )

    def _account(self, wrapped: bytes) -> str:
        if not wrapped.startswith(self._prefix):
            raise CredentialProtectionError("not a Keychain handle")
        try:
            return wrapped[len(self._prefix) :].decode("utf-8")
        except UnicodeDecodeError as exc:
            raise CredentialProtectionError("invalid Keychain handle") from exc


class WindowsDPAPIProtector:
    mode = "windows-dpapi-current-user"
    _prefix = b"dpapi-v1:"

    def __init__(self) -> None:
        if os.name != "nt":
            raise CredentialProtectionError("DPAPI is only available on Windows")

    def protect(self, label: str, secret: bytes) -> bytes:
        return self._prefix + self._crypt(secret, protect=True)

    def reveal(self, wrapped: bytes) -> bytes:
        if not wrapped.startswith(self._prefix):
            raise CredentialProtectionError("not a DPAPI blob")
        return self._crypt(wrapped[len(self._prefix) :], protect=False)

    def delete(self, wrapped: bytes) -> None:
        return None

    @staticmethod
    def _crypt(value: bytes, *, protect: bool) -> bytes:
        # Imported only on Windows; ctypes keeps DPAPI dependency-free.
        import ctypes
        from ctypes import wintypes

        class DATA_BLOB(ctypes.Structure):
            _fields_ = [
                ("cbData", wintypes.DWORD),
                ("pbData", ctypes.POINTER(ctypes.c_byte)),
            ]

        buffer = ctypes.create_string_buffer(value)
        in_blob = DATA_BLOB(
            len(value), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_byte))
        )
        out_blob = DATA_BLOB()
        if protect:
            ok = ctypes.windll.crypt32.CryptProtectData(
                ctypes.byref(in_blob), None, None, None, None, 0, ctypes.byref(out_blob)
            )
        else:
            ok = ctypes.windll.crypt32.CryptUnprotectData(
                ctypes.byref(in_blob), None, None, None, None, 0, ctypes.byref(out_blob)
            )
        if not ok:
            raise CredentialProtectionError("Windows DPAPI operation failed")
        try:
            return ctypes.string_at(out_blob.pbData, out_blob.cbData)
        finally:
            ctypes.windll.kernel32.LocalFree(out_blob.pbData)


class KeyringProtector:
    """Optional vetted keyring backend for platforms without native adapters."""

    mode = "python-keyring"
    _prefix = b"keyring-v1:"

    def __init__(self, service: str = "ai.hermes.mobile-relay") -> None:
        try:
            import keyring
        except ImportError as exc:
            raise CredentialProtectionError("keyring package unavailable") from exc
        self._keyring = keyring
        self.service = service
        backend = keyring.get_keyring()
        if getattr(backend, "priority", 0) <= 0:
            raise CredentialProtectionError("no usable keyring backend")

    def protect(self, label: str, secret: bytes) -> bytes:
        account = f"{label}:{secrets.token_urlsafe(12)}"
        try:
            self._keyring.set_password(
                self.service,
                account,
                base64.urlsafe_b64encode(secret).decode("ascii"),
            )
        except Exception as exc:
            raise CredentialProtectionError("keyring write failed") from exc
        return self._prefix + account.encode()

    def reveal(self, wrapped: bytes) -> bytes:
        account = self._account(wrapped)
        value = self._keyring.get_password(self.service, account)
        if value is None:
            raise CredentialProtectionError("keyring entry not found")
        return base64.urlsafe_b64decode(value.encode())

    def delete(self, wrapped: bytes) -> None:
        _delete_keyring_password(
            self._keyring,
            service=self.service,
            account=self._account(wrapped),
            backend_name="keyring",
        )

    def _account(self, wrapped: bytes) -> str:
        if not wrapped.startswith(self._prefix):
            raise CredentialProtectionError("not a keyring handle")
        return wrapped[len(self._prefix) :].decode()


def platform_credential_protector(
    *, allow_fallback: bool = True
) -> CredentialProtector:
    """Choose the strongest available noninteractive platform protector."""

    candidates: list[type] = []
    if platform.system() == "Darwin":
        candidates.append(MacOSKeychainProtector)
    elif os.name == "nt":
        candidates.append(WindowsDPAPIProtector)
    candidates.append(KeyringProtector)
    for candidate in candidates:
        try:
            return candidate()
        except Exception:
            continue
    if allow_fallback:
        return FilePermissionFallbackProtector()
    raise CredentialProtectionError("no OS credential protector is available")


__all__ = [
    "CredentialProtectionError",
    "CredentialProtector",
    "FilePermissionFallbackProtector",
    "KeyringProtector",
    "MacOSKeychainProtector",
    "WindowsDPAPIProtector",
    "platform_credential_protector",
]
