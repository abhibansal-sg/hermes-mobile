from __future__ import annotations

import re
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .crypto import b64url_decode


RouteType = Literal["agent", "device"]
MessageClass = Literal["realtime", "state", "command", "control"]
_OPAQUE_TOKEN = re.compile(r"^[A-Za-z0-9._~-]+$")
MAX_WIRE_INTEGER = (1 << 53) - 1


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


class ProvisionalEnrollment(StrictModel):
    enrollment_id: str = Field(pattern=r"^enr_[A-Za-z0-9._~-]{8,92}$")
    route_type: RouteType
    auth_public_key: str = Field(min_length=40, max_length=64)

    @field_validator("auth_public_key")
    @classmethod
    def valid_key(cls, value: str) -> str:
        b64url_decode(value, field="auth_public_key", exact=32)
        return value


class PendingDeviceRoute(StrictModel):
    route_type: Literal["device"]
    auth_public_key: str = Field(min_length=40, max_length=64)
    offer_id: str = Field(pattern=r"^ofr_[A-Za-z0-9._~-]{8,92}$")

    @field_validator("auth_public_key")
    @classmethod
    def valid_key(cls, value: str) -> str:
        b64url_decode(value, field="auth_public_key", exact=32)
        return value


class ActivationRequest(StrictModel):
    route_id: str = Field(pattern=r"^rte_[A-Za-z0-9._~-]{1,252}$")
    activation_token: str | None = Field(default=None, min_length=16, max_length=4096)


class GrantRequest(StrictModel):
    grant_id: str = Field(pattern=r"^grt_[A-Za-z0-9_-]{20,80}$")
    issuer_route: str = Field(pattern=r"^rte_[A-Za-z0-9._~-]{1,252}$")
    source_route: str = Field(pattern=r"^rte_[A-Za-z0-9._~-]{1,252}$")
    destination_route: str = Field(pattern=r"^rte_[A-Za-z0-9._~-]{1,252}$")
    permissions: list[Literal["send", "receive"]] = Field(min_length=1, max_length=2)
    expires_at_ms: int | None = Field(default=None, gt=0, le=MAX_WIRE_INTEGER)
    issuer_signature: str = Field(min_length=80, max_length=100)

    @field_validator("permissions")
    @classmethod
    def unique_permissions(cls, value: list[str]) -> list[str]:
        if len(value) != len(set(value)):
            raise ValueError("permissions must be unique")
        return value


class OuterEnvelope(StrictModel):
    v: Literal[2]
    src: str = Field(pattern=r"^rte_[A-Za-z0-9._~-]{1,252}$")
    dst: str = Field(pattern=r"^rte_[A-Za-z0-9._~-]{1,252}$")
    mid: str = Field(min_length=22, max_length=22)
    message_class: MessageClass = Field(alias="class")
    expires_at_ms: int = Field(gt=0, le=MAX_WIRE_INTEGER)
    recipient_key_generation: Annotated[int, Field(ge=1, le=2**32 - 1)]
    collapse: str | None = Field(max_length=64)
    enc: str = Field(min_length=1, max_length=1400)
    ct: str = Field(min_length=1, max_length=360000)
    sig: str = Field(min_length=80, max_length=100)

    @field_validator("mid")
    @classmethod
    def valid_mid(cls, value: str) -> str:
        b64url_decode(value, field="mid", exact=16)
        return value

    @field_validator("collapse")
    @classmethod
    def valid_collapse(cls, value: str | None) -> str | None:
        if value is not None:
            encoded = value.encode("utf-8")
            if not encoded or len(encoded) > 64:
                raise ValueError("collapse must be a non-empty opaque token of at most 64 bytes")
            if not _OPAQUE_TOKEN.fullmatch(value):
                raise ValueError("collapse must use the canonical opaque token alphabet")
        return value

    @field_validator("enc")
    @classmethod
    def valid_enc(cls, value: str) -> str:
        b64url_decode(value, field="enc", exact=32)
        return value

    @field_validator("ct")
    @classmethod
    def valid_ct(cls, value: str) -> str:
        raw = b64url_decode(value, field="ct", maximum=256 * 1024)
        if len(raw) < 16:
            raise ValueError("ct must contain at least the AEAD tag")
        return value

    @field_validator("sig")
    @classmethod
    def valid_sig(cls, value: str) -> str:
        b64url_decode(value, field="sig", exact=64)
        return value


class AcknowledgementRequest(StrictModel):
    message_ids: list[str] = Field(min_length=1, max_length=256)

    @field_validator("message_ids")
    @classmethod
    def valid_ids(cls, values: list[str]) -> list[str]:
        if len(values) != len(set(values)):
            raise ValueError("message_ids must be unique")
        for value in values:
            b64url_decode(value, field="message_id", exact=16)
        return values


class PairOfferCreate(StrictModel):
    offer_id: str = Field(pattern=r"^ofr_[A-Za-z0-9._~-]{8,92}$")
    offer_route: str = Field(pattern=r"^off_[A-Za-z0-9._~-]{8,92}$")
    transport_token_hash: str = Field(min_length=43, max_length=43)
    owner_route: str = Field(pattern=r"^rte_[A-Za-z0-9._~-]{1,252}$")
    expires_at_ms: int = Field(gt=0, le=MAX_WIRE_INTEGER)

    @field_validator("transport_token_hash")
    @classmethod
    def token_hash(cls, value: str) -> str:
        b64url_decode(value, field="transport_token_hash", exact=32)
        return value


class PairOfferMessage(StrictModel):
    v: Literal[2]
    offer_id: str = Field(pattern=r"^ofr_[A-Za-z0-9._~-]{8,92}$")
    enc: str = Field(min_length=43, max_length=43)
    ct: str = Field(min_length=22, max_length=43691)

    @field_validator("enc")
    @classmethod
    def valid_enc(cls, value: str) -> str:
        b64url_decode(value, field="enc", exact=32)
        return value

    @field_validator("ct")
    @classmethod
    def valid_ct(cls, value: str) -> str:
        raw = b64url_decode(value, field="ct", maximum=32 * 1024)
        if len(raw) < 16:
            raise ValueError("ct must contain at least the AEAD tag")
        return value


class PairOfferAccept(StrictModel):
    message_hash: str = Field(min_length=43, max_length=43)
    device_route: str = Field(pattern=r"^rte_[A-Za-z0-9._~-]{1,252}$")
    enc: str = Field(min_length=43, max_length=43)
    ct: str = Field(min_length=22, max_length=43691)

    @field_validator("message_hash")
    @classmethod
    def valid_hash(cls, value: str) -> str:
        b64url_decode(value, field="message_hash", exact=32)
        return value

    @field_validator("enc")
    @classmethod
    def valid_enc(cls, value: str) -> str:
        b64url_decode(value, field="enc", exact=32)
        return value

    @field_validator("ct")
    @classmethod
    def valid_ct(cls, value: str) -> str:
        raw = b64url_decode(value, field="ct", maximum=32 * 1024)
        if len(raw) < 16:
            raise ValueError("ct must contain at least the AEAD tag")
        return value


class PairOfferConfirm(StrictModel):
    message_hash: str = Field(min_length=43, max_length=43)
    response_hash: str = Field(min_length=43, max_length=43)
    device_route: str = Field(pattern=r"^rte_[A-Za-z0-9._~-]{1,252}$")

    @field_validator("message_hash", "response_hash")
    @classmethod
    def valid_hash(cls, value: str) -> str:
        b64url_decode(value, field="pairing hash", exact=32)
        return value
