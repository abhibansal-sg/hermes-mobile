"""Typed, content-safe Hermes Relay Protocol v2 errors.

Only these stable codes cross the HRP/2 boundary.  In particular, callers
must never serialize an arbitrary exception (or ``str(exc)``) into a response.
``InternalProtocolError`` intentionally accepts only a correlation identifier.
"""

from __future__ import annotations

from enum import StrEnum
from typing import Any, ClassVar, Mapping


class ErrorCode(StrEnum):
    INVALID_ARGUMENT = "INVALID_ARGUMENT"
    UNAUTHENTICATED = "UNAUTHENTICATED"
    REVOKED = "REVOKED"
    EXPIRED = "EXPIRED"
    UNSUPPORTED_VERSION = "UNSUPPORTED_VERSION"
    NOT_FOUND = "NOT_FOUND"
    CONFLICT = "CONFLICT"
    ALREADY_RESOLVED = "ALREADY_RESOLVED"
    GATEWAY_OFFLINE = "GATEWAY_OFFLINE"
    GATEWAY_AMBIGUOUS = "GATEWAY_AMBIGUOUS"
    MAILBOX_FULL = "MAILBOX_FULL"
    RATE_LIMITED = "RATE_LIMITED"
    INTERNAL = "INTERNAL"


class ProtocolError(Exception):
    """Base for errors safe to encode on an HRP/2 response."""

    code: ClassVar[ErrorCode]
    default_message: ClassVar[str]

    def __init__(
        self,
        message: str | None = None,
        *,
        details: Mapping[str, Any] | None = None,
    ) -> None:
        self.message = message or self.default_message
        self.details = dict(details or {})
        super().__init__(self.message)

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "code": self.code.value,
            "message": self.message,
        }
        if self.details:
            payload["details"] = self.details
        return payload


class InvalidArgument(ProtocolError):
    code = ErrorCode.INVALID_ARGUMENT
    default_message = "Invalid protocol argument"


class Unauthenticated(ProtocolError):
    code = ErrorCode.UNAUTHENTICATED
    default_message = "Message authentication failed"


class Revoked(ProtocolError):
    code = ErrorCode.REVOKED
    default_message = "Credential or capability was revoked"


class Expired(ProtocolError):
    code = ErrorCode.EXPIRED
    default_message = "Message or capability expired"


class UnsupportedVersion(ProtocolError):
    code = ErrorCode.UNSUPPORTED_VERSION
    default_message = "Unsupported protocol version"


class NotFound(ProtocolError):
    code = ErrorCode.NOT_FOUND
    default_message = "Resource not found"


class Conflict(ProtocolError):
    code = ErrorCode.CONFLICT
    default_message = "Protocol state conflict"


class AlreadyResolved(ProtocolError):
    code = ErrorCode.ALREADY_RESOLVED
    default_message = "Request was already resolved"


class GatewayOffline(ProtocolError):
    code = ErrorCode.GATEWAY_OFFLINE
    default_message = "Gateway is offline"


class GatewayAmbiguous(ProtocolError):
    code = ErrorCode.GATEWAY_AMBIGUOUS
    default_message = "Gateway outcome is ambiguous"


class MailboxFull(ProtocolError):
    code = ErrorCode.MAILBOX_FULL
    default_message = "Destination mailbox is full"


class RateLimited(ProtocolError):
    code = ErrorCode.RATE_LIMITED
    default_message = "Request was rate limited"


class InternalProtocolError(ProtocolError):
    """Opaque internal failure; never accepts an exception-derived message."""

    code = ErrorCode.INTERNAL
    default_message = "Internal relay error"

    def __init__(self, correlation_id: str) -> None:
        if not correlation_id or len(correlation_id) > 128:
            raise ValueError("correlation_id must contain 1..128 characters")
        self.correlation_id = correlation_id
        super().__init__(details={"correlation_id": correlation_id})


class ReplayDetected(Conflict):
    default_message = "Message was already processed"


class KeyGenerationUnavailable(Revoked):
    default_message = "Recipient key generation is unavailable"


__all__ = [
    "AlreadyResolved",
    "Conflict",
    "ErrorCode",
    "Expired",
    "GatewayAmbiguous",
    "GatewayOffline",
    "InternalProtocolError",
    "InvalidArgument",
    "KeyGenerationUnavailable",
    "MailboxFull",
    "NotFound",
    "ProtocolError",
    "RateLimited",
    "ReplayDetected",
    "Revoked",
    "Unauthenticated",
    "UnsupportedVersion",
]
