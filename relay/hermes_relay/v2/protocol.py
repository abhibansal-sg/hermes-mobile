"""Strict HRP/2 wire models and byte-stable canonical encodings.

The Relay Hub sees :class:`OuterEnvelope` only.  HPKE AAD and the Ed25519
authorization signature deliberately use binary, length-prefixed transcripts;
they never depend on JSON object order or whitespace.

Canonical transcript encoding (all integers big-endian)::

    AAD = "HRA2" || LP(u16(v), utf8(src), utf8(dst), utf8(mid),
                       utf8(class), u64(expiry), u32(key_generation),
                       utf8(collapse) or empty)
    SIG = "HRH2" || the same LP fields || LP(SHA256(enc || ct))

``LP`` prefixes every field with its unsigned 32-bit byte length.  Empty
collapse is forbidden, so a zero-length final field unambiguously means null.
JSON representations use UTF-8, sorted keys, no insignificant whitespace, and
unpadded canonical base64url for binary values.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
import struct
from collections.abc import Collection, Mapping
from dataclasses import dataclass
from enum import StrEnum
from typing import Any, Final

from .errors import InvalidArgument, UnsupportedVersion


PROTOCOL_VERSION: Final = 2
MAX_UINT32: Final = (1 << 32) - 1
MAX_WIRE_INTEGER: Final = (1 << 53) - 1
# Kept as a private-module compatibility spelling for internal validators.
# Swift represents decoded JSON numbers as Double, so every HRP/2 integer must
# stay within the shared exact range even though SQLite stores signed 64-bit.
MAX_UINT64: Final = MAX_WIRE_INTEGER
MAX_PREVIEW_PLAINTEXT_BYTES: Final = 1_200

_B64URL_RE = re.compile(r"^[A-Za-z0-9_-]+$")
_TOKEN_RE = re.compile(r"^[A-Za-z0-9._~-]+$")


class TransportClass(StrEnum):
    REALTIME = "realtime"
    STATE = "state"
    COMMAND = "command"
    CONTROL = "control"


class SecureMessageKind(StrEnum):
    PAIR_INIT = "pair.init"
    PAIR_ACCEPT = "pair.accept"
    PAIR_CONFIRM = "pair.confirm"
    FRAME_BATCH = "frame_batch"
    CHECKPOINT = "checkpoint"
    RPC_REQUEST = "rpc_request"
    RPC_RESPONSE = "rpc_response"
    STREAM_ACK = "stream_ack"
    SYNC_REQUEST = "sync_request"
    KEY_ROTATE = "key_rotate"
    DEVICE_REVOKE = "device_revoke"
    DELIVERY_RECEIPT = "delivery_receipt"


class NotificationClass(StrEnum):
    UPDATE = "update"
    APPROVAL = "approval"
    ERROR = "error"


class HPKEPurpose(StrEnum):
    CHAT = "chat"
    NOTIFICATION = "notification"
    CONTROL = "control"


class HPKEDirection(StrEnum):
    AGENT_TO_DEVICE = "agent-to-device"
    DEVICE_TO_AGENT = "device-to-agent"


def b64url_encode(value: bytes) -> str:
    """Return RFC 4648 base64url without padding."""

    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def b64url_decode(
    value: str,
    *,
    field: str,
    exact_bytes: int | None = None,
    min_bytes: int = 1,
    max_bytes: int | None = None,
) -> bytes:
    """Decode and enforce the one canonical unpadded base64url spelling."""

    if not isinstance(value, str) or not _B64URL_RE.fullmatch(value):
        raise InvalidArgument(details={"field": field})
    try:
        raw = base64.b64decode(
            value + "=" * (-len(value) % 4),
            altchars=b"-_",
            validate=True,
        )
    except (binascii.Error, ValueError) as exc:
        raise InvalidArgument(details={"field": field}) from exc
    if b64url_encode(raw) != value:
        raise InvalidArgument(details={"field": field})
    if exact_bytes is not None and len(raw) != exact_bytes:
        raise InvalidArgument(details={"field": field})
    if len(raw) < min_bytes or (max_bytes is not None and len(raw) > max_bytes):
        raise InvalidArgument(details={"field": field})
    return raw


def canonical_json(value: Any) -> bytes:
    """Encode a JSON value deterministically for HRP/2 plaintext fixtures."""

    _validate_json_value(value, field="value")
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise InvalidArgument("Value is not canonical JSON") from exc


def decode_strict_json(value: bytes) -> Any:
    """Decode UTF-8 JSON while rejecting duplicate object keys and constants."""

    def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                raise InvalidArgument(
                    "Duplicate JSON object key", details={"field": key}
                )
            result[key] = item
        return result

    def reject_constant(_: str) -> None:
        raise InvalidArgument("Non-finite JSON number")

    def parse_integer(token: str) -> int:
        if token == "-0":
            raise InvalidArgument("Negative zero is not canonical JSON")
        return int(token)

    def reject_float(_: str) -> None:
        raise InvalidArgument("Floating-point JSON numbers are not supported")

    try:
        decoded = json.loads(
            value.decode("utf-8"),
            object_pairs_hook=object_pairs,
            parse_constant=reject_constant,
            parse_int=parse_integer,
            parse_float=reject_float,
        )
    except InvalidArgument:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InvalidArgument("Malformed UTF-8 JSON") from exc
    _validate_json_value(decoded, field="value")
    return decoded


def hpke_info(purpose: HPKEPurpose, direction: HPKEDirection) -> bytes:
    try:
        normalized_purpose = HPKEPurpose(purpose)
        normalized_direction = HPKEDirection(direction)
    except (TypeError, ValueError) as exc:
        raise InvalidArgument(details={"field": "hpke_info"}) from exc
    return (
        f"hermes-mobile/hrp2/{normalized_purpose.value}/{normalized_direction.value}"
    ).encode("ascii")


def _validate_json_value(value: Any, *, field: str) -> None:
    if value is None or isinstance(value, (str, bool)):
        return
    if isinstance(value, int):
        if not -MAX_WIRE_INTEGER <= value <= MAX_WIRE_INTEGER:
            raise InvalidArgument(details={"field": field})
        return
    # HRP/2 deliberately has no floating-point wire values.  JSON's number
    # grammar admits multiple spellings whose parsers do not agree on a
    # byte-stable representation (notably -0, exponent notation, and rounded
    # binary floats).  Integers are sufficient for every HRP/2 field and keep
    # transcripts/op hashes identical across Python and Swift.
    if isinstance(value, float):
        raise InvalidArgument(details={"field": field})
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_json_value(item, field=f"{field}[{index}]")
        return
    if isinstance(value, Mapping):
        for key, item in value.items():
            if not isinstance(key, str):
                raise InvalidArgument(details={"field": field})
            _validate_json_value(item, field=f"{field}.{key}")
        return
    raise InvalidArgument(details={"field": field})


def _strict_fields(
    value: Mapping[str, Any],
    *,
    required: frozenset[str],
    optional: frozenset[str] = frozenset(),
) -> None:
    if not isinstance(value, Mapping):
        raise InvalidArgument("Expected a JSON object")
    keys = set(value)
    missing = required - keys
    extra = keys - required - optional
    if missing:
        raise InvalidArgument(
            "Missing protocol field", details={"field": sorted(missing)[0]}
        )
    if extra:
        raise InvalidArgument(
            "Unknown protocol field", details={"field": sorted(extra)[0]}
        )


def _text(value: Any, *, field: str, maximum: int = 256) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > maximum:
        raise InvalidArgument(details={"field": field})
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in value):
        raise InvalidArgument(details={"field": field})
    return value


def _token(value: Any, *, field: str, maximum: int = 256) -> str:
    text = _text(value, field=field, maximum=maximum)
    if not _TOKEN_RE.fullmatch(text):
        raise InvalidArgument(details={"field": field})
    return text


def _uint(value: Any, *, field: str, maximum: int) -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not 0 <= value <= maximum
    ):
        raise InvalidArgument(details={"field": field})
    return value


def _version(value: Any) -> int:
    normalized = _uint(value, field="v", maximum=0xFFFF)
    if normalized != PROTOCOL_VERSION:
        raise UnsupportedVersion(details={"version": normalized})
    return normalized


def _enum(enum_type: type[StrEnum], value: Any, *, field: str) -> Any:
    try:
        return enum_type(value)
    except (TypeError, ValueError) as exc:
        raise InvalidArgument(details={"field": field}) from exc


def _validate_full_item(value: Mapping[str, Any], *, field: str) -> None:
    required = frozenset({
        "item_id",
        "session_id",
        "turn_id",
        "type",
        "status",
        "ord",
        "rev",
        "summary",
        "body",
    })
    _strict_fields(value, required=required)
    _token(value["item_id"], field=f"{field}.item_id")
    _token(value["session_id"], field=f"{field}.session_id")
    if value["turn_id"] is not None:
        _token(value["turn_id"], field=f"{field}.turn_id")
    _text(value["type"], field=f"{field}.type", maximum=128)
    if value["status"] not in {"in_progress", "completed", "failed"}:
        raise InvalidArgument(details={"field": f"{field}.status"})
    _uint(value["ord"], field=f"{field}.ord", maximum=(1 << 31) - 1)
    revision = _uint(value["rev"], field=f"{field}.rev", maximum=MAX_WIRE_INTEGER)
    if revision == 0:
        raise InvalidArgument(details={"field": f"{field}.rev"})
    if not isinstance(value["summary"], str) or len(value["summary"].encode()) > 2_000:
        raise InvalidArgument(details={"field": f"{field}.summary"})
    if not isinstance(value["body"], Mapping):
        raise InvalidArgument(details={"field": f"{field}.body"})


def _validate_item_delta(value: Mapping[str, Any], *, field: str) -> None:
    _strict_fields(
        value,
        required=frozenset({"item_id", "from_rev", "to_rev", "ops"}),
    )
    _token(value["item_id"], field=f"{field}.item_id")
    from_revision = _uint(
        value["from_rev"], field=f"{field}.from_rev", maximum=MAX_WIRE_INTEGER
    )
    to_revision = _uint(
        value["to_rev"], field=f"{field}.to_rev", maximum=MAX_WIRE_INTEGER
    )
    if from_revision == 0 or to_revision != from_revision + 1:
        raise InvalidArgument(details={"field": f"{field}.to_rev"})
    operations = value["ops"]
    if not isinstance(operations, list) or len(operations) != 1:
        raise InvalidArgument(details={"field": f"{field}.ops"})
    operation = operations[0]
    _strict_fields(
        operation,
        required=frozenset({"op", "path", "offset", "data"}),
    )
    if operation["op"] != "append_utf8" or operation["path"] != "/body/text":
        raise InvalidArgument(details={"field": f"{field}.ops"})
    _uint(operation["offset"], field=f"{field}.ops.offset", maximum=10_485_760)
    if not isinstance(operation["data"], str) or len(operation["data"]) > 262_144:
        raise InvalidArgument(details={"field": f"{field}.ops.data"})


def _validate_checkpoint(value: Mapping[str, Any], *, field: str) -> None:
    _strict_fields(
        value,
        required=frozenset({
            "stream_id",
            "through_seq",
            "session_id",
            "snapshot_revision",
            "replace",
            "items",
            "tombstones",
        }),
    )
    _token(value["stream_id"], field=f"{field}.stream_id")
    _token(value["session_id"], field=f"{field}.session_id")
    _uint(value["through_seq"], field=f"{field}.through_seq", maximum=MAX_UINT64)
    _uint(
        value["snapshot_revision"],
        field=f"{field}.snapshot_revision",
        maximum=MAX_UINT64,
    )
    if not isinstance(value["replace"], bool):
        raise InvalidArgument(details={"field": f"{field}.replace"})
    items = value["items"]
    tombstones = value["tombstones"]
    if not isinstance(items, list) or len(items) > 10_000:
        raise InvalidArgument(details={"field": f"{field}.items"})
    if not isinstance(tombstones, list) or len(tombstones) > 10_000:
        raise InvalidArgument(details={"field": f"{field}.tombstones"})
    for index, item in enumerate(items):
        _validate_full_item(item, field=f"{field}.items[{index}]")
    for index, tombstone in enumerate(tombstones):
        _strict_fields(
            tombstone,
            required=frozenset({"item_id", "deleted_at_revision"}),
        )
        _token(tombstone["item_id"], field=f"{field}.tombstones[{index}].item_id")
        revision = _uint(
            tombstone["deleted_at_revision"],
            field=f"{field}.tombstones[{index}].deleted_at_revision",
            maximum=MAX_WIRE_INTEGER,
        )
        if revision == 0:
            raise InvalidArgument(
                details={"field": f"{field}.tombstones[{index}].deleted_at_revision"}
            )


def _validate_wire_frame(value: Mapping[str, Any], *, field: str) -> None:
    _strict_fields(value, required=frozenset({"sid", "turn", "kind", "body"}))
    _token(value["sid"], field=f"{field}.sid")
    if value["turn"] is not None:
        _token(value["turn"], field=f"{field}.turn")
    kinds = {
        "item.started",
        "item.delta",
        "item.completed",
        "turn.started",
        "turn.completed",
        "approval.request",
        "clarify.request",
        "status",
        "title",
        "snapshot",
        "checkpoint",
    }
    if value["kind"] not in kinds or not isinstance(value["body"], Mapping):
        raise InvalidArgument(details={"field": f"{field}.kind"})
    if value["kind"] in {"item.started", "item.completed"}:
        _validate_full_item(value["body"], field=f"{field}.body")
    elif value["kind"] == "item.delta":
        _validate_item_delta(value["body"], field=f"{field}.body")
    elif value["kind"] == "checkpoint":
        _validate_checkpoint(value["body"], field=f"{field}.body")


def _validate_secure_body(kind: SecureMessageKind, body: Mapping[str, Any]) -> None:
    """Enforce the frozen exact inner schema before encryption or dispatch."""

    exact: dict[SecureMessageKind, frozenset[str]] = {
        SecureMessageKind.PAIR_CONFIRM: frozenset({
            "offer_id",
            "device_id",
            "response_hash",
            "pair_accept_mid",
        }),
        SecureMessageKind.FRAME_BATCH: frozenset({"stream_id", "first_seq", "frames"}),
        SecureMessageKind.CHECKPOINT: frozenset({
            "stream_id",
            "through_seq",
            "session_id",
            "snapshot_revision",
            "replace",
            "items",
            "tombstones",
        }),
        SecureMessageKind.STREAM_ACK: frozenset({"stream_id", "through_seq"}),
        SecureMessageKind.SYNC_REQUEST: frozenset({
            "session_id",
            "stream_id",
            "last_seq",
        }),
        SecureMessageKind.KEY_ROTATE: frozenset({
            "purpose",
            "generation",
            "public_key",
            "previous_not_after_ms",
        }),
        SecureMessageKind.DEVICE_REVOKE: frozenset({"device_id"}),
        SecureMessageKind.DELIVERY_RECEIPT: frozenset({"mid"}),
    }
    if kind in exact:
        _strict_fields(body, required=exact[kind])
    elif kind == SecureMessageKind.RPC_REQUEST:
        _strict_fields(
            body,
            required=frozenset({"jsonrpc", "id", "method", "params"}),
            optional=frozenset({"op_id", "deadline_ms"}),
        )
        if body["jsonrpc"] != "2.0" or not isinstance(body["params"], Mapping):
            raise InvalidArgument(details={"field": "body"})
        side_effects = {
            "session.resume",
            "prompt.submit",
            "session.interrupt",
            "approval.respond",
            "clarify.respond",
        }
        if body["method"] in side_effects and "op_id" not in body:
            raise InvalidArgument(details={"field": "body.op_id"})
        if "op_id" in body:
            _token(body["op_id"], field="body.op_id")
        if "deadline_ms" in body:
            _uint(body["deadline_ms"], field="body.deadline_ms", maximum=MAX_UINT64)
    elif kind == SecureMessageKind.RPC_RESPONSE:
        _strict_fields(
            body,
            required=frozenset({"jsonrpc", "id"}),
            optional=frozenset({"result", "error"}),
        )
        if (
            body["jsonrpc"] != "2.0"
            or ("result" in body) == ("error" in body)
            or not isinstance(body.get("result", body.get("error")), Mapping)
        ):
            raise InvalidArgument(details={"field": "body"})
        if "error" in body:
            error = body["error"]
            _strict_fields(
                error,
                required=frozenset({"code", "message"}),
                optional=frozenset({"details"}),
            )
            codes = {
                "INVALID_ARGUMENT",
                "UNAUTHENTICATED",
                "REVOKED",
                "EXPIRED",
                "UNSUPPORTED_VERSION",
                "NOT_FOUND",
                "CONFLICT",
                "ALREADY_RESOLVED",
                "GATEWAY_OFFLINE",
                "GATEWAY_AMBIGUOUS",
                "MAILBOX_FULL",
                "RATE_LIMITED",
                "INTERNAL",
            }
            if error["code"] not in codes:
                raise InvalidArgument(details={"field": "body.error.code"})
            _text(error["message"], field="body.error.message", maximum=512)
            if "details" in error and not isinstance(error["details"], Mapping):
                raise InvalidArgument(details={"field": "body.error.details"})
    elif kind == SecureMessageKind.PAIR_ACCEPT:
        _strict_fields(
            body,
            required=frozenset({
                "device_id",
                "relay_instance_id",
                "device_route",
                "stream_id",
                "relay_key_generation",
                "push_binding_id",
                "capabilities",
            }),
        )

    for field in {
        "offer_id",
        "device_id",
        "pair_accept_mid",
        "stream_id",
        "session_id",
        "mid",
        "id",
        "method",
    }.intersection(body):
        _token(body[field], field=f"body.{field}", maximum=256)
    for field in {
        "first_seq",
        "through_seq",
        "last_seq",
        "generation",
        "previous_not_after_ms",
        "relay_key_generation",
    }.intersection(body):
        value = _uint(body[field], field=f"body.{field}", maximum=MAX_UINT64)
        if field in {"generation", "relay_key_generation"} and value == 0:
            raise InvalidArgument(details={"field": f"body.{field}"})
    if kind == SecureMessageKind.FRAME_BATCH and not isinstance(body["frames"], list):
        raise InvalidArgument(details={"field": "body.frames"})
    if kind == SecureMessageKind.FRAME_BATCH:
        frames = body["frames"]
        if body["first_seq"] == 0:
            raise InvalidArgument(details={"field": "body.first_seq"})
        if not 1 <= len(frames) <= 1_024:
            raise InvalidArgument(details={"field": "body.frames"})
        for index, frame in enumerate(frames):
            _validate_wire_frame(frame, field=f"body.frames[{index}]")
    if kind == SecureMessageKind.CHECKPOINT:
        _validate_checkpoint(body, field="body")
    if kind == SecureMessageKind.KEY_ROTATE:
        if body["purpose"] not in {"kem", "preview"}:
            raise InvalidArgument(details={"field": "body.purpose"})
        b64url_decode(body["public_key"], field="body.public_key", exact_bytes=32)
    if kind == SecureMessageKind.PAIR_CONFIRM:
        b64url_decode(body["response_hash"], field="body.response_hash", exact_bytes=32)
        _message_id(body["pair_accept_mid"], field="body.pair_accept_mid")
    if kind == SecureMessageKind.DELIVERY_RECEIPT:
        _message_id(body["mid"], field="body.mid")
    if kind == SecureMessageKind.PAIR_ACCEPT:
        for field in ("device_id", "relay_instance_id", "device_route", "stream_id"):
            _token(body[field], field=f"body.{field}")
        if body["push_binding_id"] is not None:
            _token(body["push_binding_id"], field="body.push_binding_id")
        capabilities = body["capabilities"]
        allowed = {"chat", "history", "notifications", "approve_once", "deny"}
        if (
            not isinstance(capabilities, list)
            or not 1 <= len(capabilities) <= 16
            or len(capabilities) != len(set(capabilities))
            or not set(capabilities).issubset(allowed)
        ):
            raise InvalidArgument(details={"field": "body.capabilities"})


def _message_id(value: Any, *, field: str = "mid") -> str:
    if not isinstance(value, str):
        raise InvalidArgument(details={"field": field})
    b64url_decode(value, field=field, exact_bytes=16)
    return value


def _lp(domain: bytes, *fields: bytes) -> bytes:
    encoded = bytearray(domain)
    for field in fields:
        if len(field) > MAX_UINT32:
            raise InvalidArgument("Canonical field is too large")
        encoded.extend(struct.pack(">I", len(field)))
        encoded.extend(field)
    return bytes(encoded)


@dataclass(frozen=True, slots=True)
class OuterHeader:
    src: str
    dst: str
    mid: str
    message_class: TransportClass
    expires_at_ms: int
    recipient_key_generation: int
    collapse: str | None = None
    v: int = PROTOCOL_VERSION

    def __post_init__(self) -> None:
        object.__setattr__(self, "v", _version(self.v))
        object.__setattr__(self, "src", _token(self.src, field="src"))
        object.__setattr__(self, "dst", _token(self.dst, field="dst"))
        object.__setattr__(self, "mid", _message_id(self.mid))
        object.__setattr__(
            self,
            "message_class",
            _enum(TransportClass, self.message_class, field="class"),
        )
        object.__setattr__(
            self,
            "expires_at_ms",
            _uint(self.expires_at_ms, field="expires_at_ms", maximum=MAX_UINT64),
        )
        generation = _uint(
            self.recipient_key_generation,
            field="recipient_key_generation",
            maximum=MAX_UINT32,
        )
        if generation == 0:
            raise InvalidArgument(details={"field": "recipient_key_generation"})
        object.__setattr__(self, "recipient_key_generation", generation)
        if self.collapse is not None:
            object.__setattr__(
                self, "collapse", _token(self.collapse, field="collapse", maximum=64)
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "v": self.v,
            "src": self.src,
            "dst": self.dst,
            "mid": self.mid,
            "class": self.message_class.value,
            "expires_at_ms": self.expires_at_ms,
            "recipient_key_generation": self.recipient_key_generation,
            "collapse": self.collapse,
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "OuterHeader":
        required = frozenset({
            "v",
            "src",
            "dst",
            "mid",
            "class",
            "expires_at_ms",
            "recipient_key_generation",
            "collapse",
        })
        _strict_fields(value, required=required)
        return cls(
            v=value["v"],
            src=value["src"],
            dst=value["dst"],
            mid=value["mid"],
            message_class=value["class"],
            expires_at_ms=value["expires_at_ms"],
            recipient_key_generation=value["recipient_key_generation"],
            collapse=value["collapse"],
        )

    def _transcript(self, domain: bytes, *suffix: bytes) -> bytes:
        collapse = b"" if self.collapse is None else self.collapse.encode("utf-8")
        return _lp(
            domain,
            self.v.to_bytes(2, "big"),
            self.src.encode("utf-8"),
            self.dst.encode("utf-8"),
            self.mid.encode("ascii"),
            self.message_class.value.encode("ascii"),
            self.expires_at_ms.to_bytes(8, "big"),
            self.recipient_key_generation.to_bytes(4, "big"),
            collapse,
            *suffix,
        )

    def aad(self) -> bytes:
        return self._transcript(b"HRA2")

    def signature_payload(self, enc: bytes, ct: bytes) -> bytes:
        return self._transcript(b"HRH2", hashlib.sha256(enc + ct).digest())


@dataclass(frozen=True, slots=True)
class OuterEnvelope(OuterHeader):
    enc: bytes = b""
    ct: bytes = b""
    sig: bytes = b""

    def __post_init__(self) -> None:
        super(OuterEnvelope, self).__post_init__()
        if not isinstance(self.enc, bytes) or len(self.enc) != 32:
            raise InvalidArgument(details={"field": "enc"})
        if not isinstance(self.ct, bytes) or len(self.ct) < 16:
            raise InvalidArgument(details={"field": "ct"})
        if not isinstance(self.sig, bytes) or len(self.sig) != 64:
            raise InvalidArgument(details={"field": "sig"})

    @property
    def header(self) -> OuterHeader:
        return OuterHeader(
            v=self.v,
            src=self.src,
            dst=self.dst,
            mid=self.mid,
            message_class=self.message_class,
            expires_at_ms=self.expires_at_ms,
            recipient_key_generation=self.recipient_key_generation,
            collapse=self.collapse,
        )

    def to_dict(self) -> dict[str, Any]:
        result = super(OuterEnvelope, self).to_dict()
        result.update({
            "enc": b64url_encode(self.enc),
            "ct": b64url_encode(self.ct),
            "sig": b64url_encode(self.sig),
        })
        return result

    def to_json(self) -> bytes:
        return canonical_json(self.to_dict())

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "OuterEnvelope":
        required = frozenset({
            "v",
            "src",
            "dst",
            "mid",
            "class",
            "expires_at_ms",
            "recipient_key_generation",
            "collapse",
            "enc",
            "ct",
            "sig",
        })
        _strict_fields(value, required=required)
        return cls(
            v=value["v"],
            src=value["src"],
            dst=value["dst"],
            mid=value["mid"],
            message_class=value["class"],
            expires_at_ms=value["expires_at_ms"],
            recipient_key_generation=value["recipient_key_generation"],
            collapse=value["collapse"],
            enc=b64url_decode(value["enc"], field="enc", exact_bytes=32),
            ct=b64url_decode(value["ct"], field="ct", min_bytes=16, max_bytes=262_160),
            sig=b64url_decode(value["sig"], field="sig", exact_bytes=64),
        )

    @classmethod
    def from_json(cls, value: bytes) -> "OuterEnvelope":
        decoded = decode_strict_json(value)
        if not isinstance(decoded, dict):
            raise InvalidArgument("Expected an envelope object")
        return cls.from_dict(decoded)


@dataclass(frozen=True, slots=True)
class SecureMessage:
    mid: str
    kind: SecureMessageKind
    sender_key_generation: int
    created_at_ms: int
    expires_at_ms: int
    body: Mapping[str, Any]
    v: int = PROTOCOL_VERSION

    def __post_init__(self) -> None:
        object.__setattr__(self, "v", _version(self.v))
        object.__setattr__(self, "mid", _message_id(self.mid))
        object.__setattr__(
            self, "kind", _enum(SecureMessageKind, self.kind, field="kind")
        )
        generation = _uint(
            self.sender_key_generation,
            field="sender_key_generation",
            maximum=MAX_UINT32,
        )
        if generation == 0:
            raise InvalidArgument(details={"field": "sender_key_generation"})
        object.__setattr__(self, "sender_key_generation", generation)
        object.__setattr__(
            self,
            "created_at_ms",
            _uint(self.created_at_ms, field="created_at_ms", maximum=MAX_UINT64),
        )
        object.__setattr__(
            self,
            "expires_at_ms",
            _uint(self.expires_at_ms, field="expires_at_ms", maximum=MAX_UINT64),
        )
        if self.created_at_ms > self.expires_at_ms:
            raise InvalidArgument(details={"field": "expires_at_ms"})
        if not isinstance(self.body, Mapping):
            raise InvalidArgument(details={"field": "body"})
        normalized_body = dict(self.body)
        _validate_json_value(normalized_body, field="body")
        _validate_secure_body(self.kind, normalized_body)
        object.__setattr__(self, "body", normalized_body)

    def to_dict(self) -> dict[str, Any]:
        return {
            "v": self.v,
            "mid": self.mid,
            "kind": self.kind.value,
            "sender_key_generation": self.sender_key_generation,
            "created_at_ms": self.created_at_ms,
            "expires_at_ms": self.expires_at_ms,
            "body": dict(self.body),
        }

    def to_bytes(self) -> bytes:
        return canonical_json(self.to_dict())

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "SecureMessage":
        required = frozenset({
            "v",
            "mid",
            "kind",
            "sender_key_generation",
            "created_at_ms",
            "expires_at_ms",
            "body",
        })
        _strict_fields(value, required=required)
        return cls(**{key: value[key] for key in required})

    @classmethod
    def from_bytes(cls, value: bytes) -> "SecureMessage":
        decoded = decode_strict_json(value)
        if not isinstance(decoded, dict):
            raise InvalidArgument("Expected a secure-message object")
        return cls.from_dict(decoded)


@dataclass(frozen=True, slots=True)
class ReceiveContext:
    expected_destination: str
    now_ms: int
    seen_message_ids: Collection[str] = frozenset()
    expected_source: str | None = None

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "expected_destination",
            _token(self.expected_destination, field="expected_destination"),
        )
        object.__setattr__(
            self, "now_ms", _uint(self.now_ms, field="now_ms", maximum=MAX_UINT64)
        )
        if self.expected_source is not None:
            object.__setattr__(
                self,
                "expected_source",
                _token(self.expected_source, field="expected_source"),
            )
        if not isinstance(self.seen_message_ids, Collection):
            raise InvalidArgument(details={"field": "seen_message_ids"})


@dataclass(frozen=True, slots=True)
class NotificationPreview:
    notification_id: str
    notification_class: NotificationClass
    title: str
    body: str
    thread_token: str
    expires_at_ms: int
    category: str | None = None
    action: Mapping[str, Any] | None = None
    v: int = PROTOCOL_VERSION

    def __post_init__(self) -> None:
        object.__setattr__(self, "v", _version(self.v))
        object.__setattr__(
            self,
            "notification_id",
            _token(self.notification_id, field="notification_id"),
        )
        object.__setattr__(
            self,
            "notification_class",
            _enum(NotificationClass, self.notification_class, field="class"),
        )
        object.__setattr__(self, "title", _text(self.title, field="title", maximum=200))
        object.__setattr__(self, "body", _text(self.body, field="body", maximum=1_200))
        object.__setattr__(
            self, "thread_token", _token(self.thread_token, field="thread_token")
        )
        object.__setattr__(
            self,
            "expires_at_ms",
            _uint(self.expires_at_ms, field="expires_at_ms", maximum=MAX_UINT64),
        )
        if self.category is not None:
            object.__setattr__(
                self, "category", _token(self.category, field="category")
            )
        if self.action is not None:
            if not isinstance(self.action, Mapping):
                raise InvalidArgument(details={"field": "action"})
            action = dict(self.action)
            if self.notification_class != NotificationClass.APPROVAL:
                raise InvalidArgument(details={"field": "action"})
            _strict_fields(
                action,
                required=frozenset({
                    "request_id",
                    "session_id",
                    "capability",
                    "allowed_decisions",
                    "destructive",
                    "device_id",
                    "device_generation",
                }),
            )
            for field in ("request_id", "session_id", "capability", "device_id"):
                _token(action[field], field=f"action.{field}", maximum=256)
            b64url_decode(
                action["capability"], field="action.capability", exact_bytes=32
            )
            generation = _uint(
                action["device_generation"],
                field="action.device_generation",
                maximum=MAX_UINT32,
            )
            if generation == 0:
                raise InvalidArgument(details={"field": "action.device_generation"})
            if not isinstance(action["destructive"], bool):
                raise InvalidArgument(details={"field": "action.destructive"})
            decisions = action["allowed_decisions"]
            if (
                not isinstance(decisions, list)
                or not decisions
                or len(decisions) != len(set(decisions))
                or not set(decisions).issubset({"approve_once", "deny"})
            ):
                raise InvalidArgument(details={"field": "action.allowed_decisions"})
            _validate_json_value(action, field="action")
            object.__setattr__(self, "action", action)

    def to_dict(self) -> dict[str, Any]:
        return {
            "v": self.v,
            "notification_id": self.notification_id,
            "class": self.notification_class.value,
            "title": self.title,
            "body": self.body,
            "thread_token": self.thread_token,
            "category": self.category,
            "expires_at_ms": self.expires_at_ms,
            "action": None if self.action is None else dict(self.action),
        }

    def to_bytes(self) -> bytes:
        encoded = canonical_json(self.to_dict())
        if len(encoded) > MAX_PREVIEW_PLAINTEXT_BYTES:
            raise InvalidArgument("Notification preview exceeds 1,200 UTF-8 bytes")
        return encoded

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "NotificationPreview":
        required = frozenset({
            "v",
            "notification_id",
            "class",
            "title",
            "body",
            "thread_token",
            "category",
            "expires_at_ms",
            "action",
        })
        _strict_fields(value, required=required)
        return cls(
            v=value["v"],
            notification_id=value["notification_id"],
            notification_class=value["class"],
            title=value["title"],
            body=value["body"],
            thread_token=value["thread_token"],
            category=value["category"],
            expires_at_ms=value["expires_at_ms"],
            action=value["action"],
        )

    @classmethod
    def from_bytes(cls, value: bytes) -> "NotificationPreview":
        if len(value) > MAX_PREVIEW_PLAINTEXT_BYTES:
            raise InvalidArgument("Notification preview exceeds 1,200 UTF-8 bytes")
        decoded = decode_strict_json(value)
        if not isinstance(decoded, dict):
            raise InvalidArgument("Expected a notification-preview object")
        return cls.from_dict(decoded)


@dataclass(frozen=True, slots=True)
class NotificationSendDescriptor:
    notification_id: str
    notification_class: NotificationClass
    preview_enc: bytes
    preview_ct: bytes
    expires_at_ms: int
    collapse_id: str | None = None
    sound: bool = True
    v: int = PROTOCOL_VERSION

    def __post_init__(self) -> None:
        object.__setattr__(self, "v", _version(self.v))
        object.__setattr__(
            self,
            "notification_id",
            _token(self.notification_id, field="notification_id"),
        )
        object.__setattr__(
            self,
            "notification_class",
            _enum(NotificationClass, self.notification_class, field="class"),
        )
        if not isinstance(self.preview_enc, bytes) or len(self.preview_enc) != 32:
            raise InvalidArgument(details={"field": "preview_enc"})
        if not isinstance(self.preview_ct, bytes) or len(self.preview_ct) < 16:
            raise InvalidArgument(details={"field": "preview_ct"})
        object.__setattr__(
            self,
            "expires_at_ms",
            _uint(self.expires_at_ms, field="expires_at_ms", maximum=MAX_UINT64),
        )
        if self.collapse_id is not None:
            object.__setattr__(
                self,
                "collapse_id",
                _token(self.collapse_id, field="collapse_id", maximum=64),
            )
        if not isinstance(self.sound, bool):
            raise InvalidArgument(details={"field": "sound"})

    def aad(self) -> bytes:
        collapse = b"" if self.collapse_id is None else self.collapse_id.encode("utf-8")
        return _lp(
            b"HRN2",
            self.v.to_bytes(2, "big"),
            self.notification_class.value.encode("ascii"),
            self.notification_id.encode("utf-8"),
            self.expires_at_ms.to_bytes(8, "big"),
            collapse,
            b"\x01" if self.sound else b"\x00",
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "v": self.v,
            "class": self.notification_class.value,
            "notification_id": self.notification_id,
            "preview_enc": b64url_encode(self.preview_enc),
            "preview_ct": b64url_encode(self.preview_ct),
            "collapse_id": self.collapse_id,
            "expires_at_ms": self.expires_at_ms,
            "sound": self.sound,
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "NotificationSendDescriptor":
        required = frozenset({
            "v",
            "class",
            "notification_id",
            "preview_enc",
            "preview_ct",
            "collapse_id",
            "expires_at_ms",
            "sound",
        })
        _strict_fields(value, required=required)
        return cls(
            v=value["v"],
            notification_class=value["class"],
            notification_id=value["notification_id"],
            preview_enc=b64url_decode(
                value["preview_enc"], field="preview_enc", exact_bytes=32
            ),
            preview_ct=b64url_decode(
                value["preview_ct"], field="preview_ct", min_bytes=16, max_bytes=4_096
            ),
            collapse_id=value["collapse_id"],
            expires_at_ms=value["expires_at_ms"],
            sound=value["sound"],
        )


__all__ = [
    "HPKEDirection",
    "HPKEPurpose",
    "MAX_WIRE_INTEGER",
    "MAX_PREVIEW_PLAINTEXT_BYTES",
    "NotificationClass",
    "NotificationPreview",
    "NotificationSendDescriptor",
    "OuterEnvelope",
    "OuterHeader",
    "PROTOCOL_VERSION",
    "ReceiveContext",
    "SecureMessage",
    "SecureMessageKind",
    "TransportClass",
    "b64url_decode",
    "b64url_encode",
    "canonical_json",
    "decode_strict_json",
    "hpke_info",
]
