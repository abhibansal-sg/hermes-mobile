from __future__ import annotations

import base64
import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .crypto import b64url_decode


Environment = Literal["production", "sandbox"]
NotificationClass = Literal["update", "approval", "error"]
MAX_WIRE_INTEGER = (1 << 53) - 1
_TOKEN = re.compile(r"^[A-Za-z0-9._~-]+$")


def _canonical_app_attest_key_id(value: str) -> str:
    try:
        raw = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise ValueError("app_attest_key_id must be canonical standard base64") from exc
    if len(raw) != 32 or base64.b64encode(raw).decode("ascii") != value:
        raise ValueError(
            "app_attest_key_id must be canonical standard base64 of 32 bytes"
        )
    return value


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class EndpointRegistration(StrictModel):
    challenge: str = Field(min_length=20, max_length=100)
    app_attest_key_id: str = Field(min_length=16, max_length=256)
    assertion: str = Field(min_length=16, max_length=16384)
    attestation: str | None = Field(default=None, min_length=16, max_length=32768)
    apns_token: str = Field(min_length=2, max_length=512, pattern=r"^[a-f0-9]+$")
    environment: Environment
    bundle_id: str = Field(min_length=3, max_length=160, pattern=r"^[A-Za-z0-9.-]+$")
    preview_kem_pub: str = Field(min_length=40, max_length=200)
    installation_nonce: str = Field(min_length=16, max_length=200)
    hub_route_id: str | None = Field(default=None, min_length=5, max_length=96)

    @field_validator("app_attest_key_id")
    @classmethod
    def canonical_key_id(cls, value: str) -> str:
        return _canonical_app_attest_key_id(value)

    @field_validator("preview_kem_pub")
    @classmethod
    def preview_key(cls, value: str) -> str:
        b64url_decode(value, field="preview_kem_pub", exact=32)
        return value

    @field_validator("installation_nonce")
    @classmethod
    def nonce(cls, value: str) -> str:
        raw = b64url_decode(value, field="installation_nonce", maximum=64)
        if len(raw) < 16:
            raise ValueError("installation_nonce must decode to at least 16 bytes")
        return value

    @field_validator("apns_token")
    @classmethod
    def canonical_apns_token(cls, value: str) -> str:
        if len(value) % 2:
            raise ValueError("apns_token must be even-length canonical hex")
        return value


class EndpointTokenRefresh(StrictModel):
    endpoint_id: str = Field(pattern=r"^ep_[A-Za-z0-9_-]{20,80}$")
    challenge: str = Field(min_length=20, max_length=100)
    app_attest_key_id: str = Field(min_length=16, max_length=256)
    assertion: str = Field(min_length=16, max_length=16384)
    apns_token: str = Field(min_length=2, max_length=512, pattern=r"^[a-f0-9]+$")
    environment: Environment
    bundle_id: str = Field(min_length=3, max_length=160, pattern=r"^[A-Za-z0-9.-]+$")
    preview_kem_pub: str = Field(min_length=40, max_length=200)
    installation_nonce: str = Field(min_length=16, max_length=200)

    @field_validator("app_attest_key_id")
    @classmethod
    def canonical_key_id(cls, value: str) -> str:
        return _canonical_app_attest_key_id(value)

    @field_validator("preview_kem_pub")
    @classmethod
    def preview_key(cls, value: str) -> str:
        b64url_decode(value, field="preview_kem_pub", exact=32)
        return value

    @field_validator("installation_nonce")
    @classmethod
    def nonce(cls, value: str) -> str:
        raw = b64url_decode(value, field="installation_nonce", maximum=64)
        if len(raw) < 16:
            raise ValueError("installation_nonce must decode to at least 16 bytes")
        return value

    @field_validator("apns_token")
    @classmethod
    def canonical_apns_token(cls, value: str) -> str:
        if len(value) % 2:
            raise ValueError("apns_token must be even-length canonical hex")
        return value


class HubActivationRequest(StrictModel):
    challenge: str = Field(min_length=20, max_length=100)
    app_attest_key_id: str = Field(min_length=16, max_length=256)
    assertion: str = Field(min_length=16, max_length=16384)
    attestation: str | None = Field(default=None, min_length=16, max_length=32768)
    hub_route_id: str = Field(pattern=r"^rte_[A-Za-z0-9._~-]{1,252}$")
    environment: Environment
    bundle_id: str = Field(min_length=3, max_length=160, pattern=r"^[A-Za-z0-9.-]+$")
    installation_nonce: str = Field(min_length=16, max_length=200)

    @field_validator("app_attest_key_id")
    @classmethod
    def canonical_key_id(cls, value: str) -> str:
        return _canonical_app_attest_key_id(value)

    @field_validator("installation_nonce")
    @classmethod
    def nonce(cls, value: str) -> str:
        raw = b64url_decode(value, field="installation_nonce", maximum=64)
        if len(raw) < 16:
            raise ValueError("installation_nonce must decode to at least 16 bytes")
        return value


class BindingExchange(StrictModel):
    bind_token: str = Field(min_length=32, max_length=200)
    exchange_id: str = Field(
        min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._~-]+$"
    )
    requested_classes: list[NotificationClass] | None = Field(
        default=None, min_length=1, max_length=3
    )

    @field_validator("requested_classes")
    @classmethod
    def unique_classes(cls, value: list[str] | None) -> list[str] | None:
        if value is not None and len(value) != len(set(value)):
            raise ValueError("requested_classes must be unique")
        return value


class BindingExchangeRevoke(StrictModel):
    bind_token: str = Field(min_length=32, max_length=200)
    exchange_id: str = Field(
        min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._~-]+$"
    )


class SendRequest(StrictModel):
    v: Literal[2]
    notification_class: NotificationClass = Field(alias="class")
    notification_id: str = Field(min_length=1, max_length=128)
    preview_enc: str = Field(min_length=40, max_length=200)
    preview_ct: str = Field(min_length=22, max_length=5462)
    collapse_id: str | None = Field(min_length=1, max_length=64)
    expires_at_ms: int = Field(gt=0, le=MAX_WIRE_INTEGER)
    sound: bool

    @field_validator("notification_id", "collapse_id")
    @classmethod
    def opaque_token(cls, value: str | None) -> str | None:
        if value is not None and not _TOKEN.fullmatch(value):
            raise ValueError("must be an opaque printable token")
        return value

    @field_validator("preview_enc")
    @classmethod
    def enc(cls, value: str) -> str:
        b64url_decode(value, field="preview_enc", exact=32)
        return value

    @field_validator("preview_ct")
    @classmethod
    def ciphertext(cls, value: str) -> str:
        raw = b64url_decode(value, field="preview_ct", maximum=4096)
        if len(raw) < 16:
            raise ValueError("preview_ct must contain at least the AEAD tag")
        return value
