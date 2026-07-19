"""Strict encrypted JSON-RPC v2 validation and crash-safe dispatch."""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass
from typing import Any, Mapping

from ..gateway_client import GatewayClient, GatewayRPCError
from .device_router import DeviceRouter
from .projection import V2Projection
from .protocol import MAX_WIRE_INTEGER, TransportClass
from .errors import (
    AlreadyResolved,
    Conflict,
    ErrorCode,
    Expired,
    GatewayAmbiguous,
    GatewayOffline,
    InternalProtocolError,
    InvalidArgument,
    NotFound,
    ProtocolError,
    Revoked,
)
from .storage import (
    RelayStorage,
    StorageConflict,
    StorageExpired,
    StorageNotFound,
    random_id,
)


SUPPORTED_METHODS = frozenset({
    "session.list",
    "session.open",
    "session.history",
    "session.resume",
    "prompt.submit",
    "session.interrupt",
    "approval.respond",
    "clarify.respond",
    "presence.set",
    "item.fetch",
    "sync.request",
})
SIDE_EFFECTING_METHODS = frozenset({
    "session.resume",
    "prompt.submit",
    "session.interrupt",
    "approval.respond",
    "clarify.respond",
})


def _strict(
    value: Mapping[str, Any], required: set[str], optional: set[str] = set()
) -> None:
    if not isinstance(value, Mapping):
        raise InvalidArgument("Expected a JSON object")
    missing = required - set(value)
    extra = set(value) - required - optional
    if missing or extra:
        raise InvalidArgument(details={"field": sorted(missing or extra)[0]})


def _string(value: Any, field: str, *, minimum: int = 1, maximum: int = 256) -> str:
    if not isinstance(value, str):
        raise InvalidArgument(details={"field": field})
    size = len(value.encode("utf-8"))
    if not minimum <= size <= maximum:
        raise InvalidArgument(details={"field": field})
    return value


def _integer(
    value: Any,
    field: str,
    *,
    minimum: int = 0,
    maximum: int = MAX_WIRE_INTEGER,
) -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not minimum <= value <= maximum
    ):
        raise InvalidArgument(details={"field": field})
    return value


def _canonical_uuid(value: Any, field: str) -> str:
    """Return a lowercase hyphenated UUID accepted by Gateway receipts."""

    text = _string(value, field, minimum=36, maximum=36)
    try:
        canonical = str(uuid.UUID(text))
    except (ValueError, AttributeError) as exc:
        raise InvalidArgument(details={"field": field}) from exc
    if canonical != text:
        raise InvalidArgument(details={"field": field})
    return text


def validate_params(method: str, value: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise InvalidArgument(details={"field": "params"})
    params = dict(value)
    if method == "session.list":
        _strict(params, set(), {"limit"})
        if "limit" in params:
            params["limit"] = _integer(
                params["limit"], "limit", minimum=1, maximum=1000
            )
    elif method in {"session.open", "session.resume", "session.interrupt"}:
        _strict(params, {"session_id"})
        params["session_id"] = _string(params["session_id"], "session_id")
    elif method == "session.history":
        _strict(params, {"session_id"}, {"limit"})
        params["session_id"] = _string(params["session_id"], "session_id")
        if "limit" in params:
            params["limit"] = _integer(
                params["limit"], "limit", minimum=1, maximum=5000
            )
    elif method == "prompt.submit":
        _strict(
            params,
            {"text", "client_message_id"},
            {"session_id", "title", "model", "provider"},
        )
        params["text"] = _string(params["text"], "text", maximum=1_000_000)
        params["client_message_id"] = _canonical_uuid(
            params["client_message_id"], "client_message_id"
        )
        for field, maximum in (
            ("session_id", 256),
            ("title", 200),
            ("model", 200),
            ("provider", 200),
        ):
            if field in params and params[field] is not None:
                params[field] = _string(params[field], field, maximum=maximum)
    elif method == "approval.respond":
        _strict(params, {"session_id", "request_id", "decision", "capability"})
        params["session_id"] = _string(params["session_id"], "session_id")
        params["request_id"] = _string(params["request_id"], "request_id")
        params["capability"] = _string(
            params["capability"], "capability", minimum=43, maximum=43
        )
        if params["decision"] not in {"approve_once", "deny"}:
            raise InvalidArgument(details={"field": "decision"})
    elif method == "clarify.respond":
        _strict(params, {"session_id", "request_id", "text"})
        params["session_id"] = _string(params["session_id"], "session_id")
        params["request_id"] = _string(params["request_id"], "request_id")
        params["text"] = _string(params["text"], "text", maximum=100_000)
    elif method == "presence.set":
        _strict(params, {"foreground"}, {"session_id"})
        if not isinstance(params["foreground"], bool):
            raise InvalidArgument(details={"field": "foreground"})
        if params.get("session_id") is not None:
            params["session_id"] = _string(params["session_id"], "session_id")
        if params["foreground"] and not params.get("session_id"):
            raise InvalidArgument(details={"field": "session_id"})
    elif method == "item.fetch":
        _strict(params, {"session_id", "item_id"})
        params["session_id"] = _string(params["session_id"], "session_id")
        params["item_id"] = _string(params["item_id"], "item_id")
    elif method == "sync.request":
        _strict(params, {"session_id"}, {"last_seq", "stream_id"})
        params["session_id"] = _string(params["session_id"], "session_id")
        if "last_seq" in params:
            params["last_seq"] = _integer(params["last_seq"], "last_seq")
        if "stream_id" in params:
            params["stream_id"] = _string(params["stream_id"], "stream_id")
    else:
        raise InvalidArgument("Unsupported RPC method", details={"field": "method"})
    return params


@dataclass(frozen=True, slots=True)
class RPCRequest:
    id: str
    method: str
    params: Mapping[str, Any]
    op_id: str | None = None
    deadline_ms: int | None = None
    jsonrpc: str = "2.0"

    def __post_init__(self) -> None:
        if self.jsonrpc != "2.0":
            raise InvalidArgument(details={"field": "jsonrpc"})
        object.__setattr__(self, "id", _string(self.id, "id", maximum=128))
        if self.method not in SUPPORTED_METHODS:
            raise InvalidArgument("Unsupported RPC method", details={"field": "method"})
        object.__setattr__(self, "params", validate_params(self.method, self.params))
        if self.method in SIDE_EFFECTING_METHODS and self.op_id is None:
            raise InvalidArgument(details={"field": "op_id"})
        if self.op_id is not None:
            object.__setattr__(
                self, "op_id", _string(self.op_id, "op_id", minimum=8, maximum=128)
            )
        if self.deadline_ms is not None:
            object.__setattr__(
                self, "deadline_ms", _integer(self.deadline_ms, "deadline_ms")
            )

    @classmethod
    def from_dict(
        cls, value: Mapping[str, Any], *, now_ms: int | None = None
    ) -> "RPCRequest":
        _strict(value, {"jsonrpc", "id", "method", "params"}, {"op_id", "deadline_ms"})
        request = cls(
            jsonrpc=value["jsonrpc"],
            id=value["id"],
            method=value["method"],
            params=value["params"],
            op_id=value.get("op_id"),
            deadline_ms=value.get("deadline_ms"),
        )
        at = now_ms if now_ms is not None else time.time_ns() // 1_000_000
        if request.deadline_ms is not None and request.deadline_ms <= at:
            raise Expired(details={"id": request.id})
        return request


@dataclass(frozen=True, slots=True)
class RPCResponse:
    id: str
    result: Mapping[str, Any] | None = None
    error: ProtocolError | None = None

    def __post_init__(self) -> None:
        if (self.result is None) == (self.error is None):
            raise ValueError("response must contain exactly one of result/error")

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {"jsonrpc": "2.0", "id": self.id}
        if self.error is not None:
            payload["error"] = self.error.to_dict()
        else:
            payload["result"] = dict(self.result or {})
        return payload


class RPCDispatcher:
    def __init__(
        self,
        gateway: GatewayClient,
        storage: RelayStorage,
        router: DeviceRouter,
    ) -> None:
        self.gateway = gateway
        self.storage = storage
        self.router = router
        candidate_projection = getattr(router, "projection", None)
        self.projection = (
            candidate_projection
            if isinstance(candidate_projection, V2Projection)
            else V2Projection(storage)
        )

    async def dispatch(self, device_id: str, request: RPCRequest) -> RPCResponse:
        device = self.storage.get_device(device_id)
        if device is None:
            return RPCResponse(request.id, error=Revoked())
        if request.method not in SIDE_EFFECTING_METHODS:
            try:
                return RPCResponse(
                    request.id, result=await self._execute(device_id, request)
                )
            except ProtocolError as exc:
                return RPCResponse(request.id, error=exc)
            except (ConnectionError, TimeoutError):
                return RPCResponse(request.id, error=GatewayOffline())
            except GatewayRPCError as exc:
                return RPCResponse(request.id, error=self._gateway_error(exc))
            except Exception:
                return RPCResponse(
                    request.id, error=InternalProtocolError(uuid.uuid4().hex)
                )

        assert request.op_id is not None
        try:
            operation = self.storage.begin_operation(
                device_id, request.op_id, request.method, request.params
            )
        except StorageConflict:
            return RPCResponse(request.id, error=Conflict("op_id request conflict"))
        if operation.state == "succeeded":
            return RPCResponse(request.id, result=operation.response or {})
        approval_claim: dict[str, Any] | None = None
        if request.method == "approval.respond" and operation.state in {
            "received",
            "ambiguous",
        }:
            try:
                approval_claim = self.storage.claim_approval_capability(
                    capability=request.params["capability"],
                    device_id=device_id,
                    device_generation=device.kem_generation,
                    request_id=request.params["request_id"],
                    session_id=self.storage.origin_session_id(
                        request.params["session_id"]
                    ),
                    decision=request.params["decision"],
                    op_id=request.op_id,
                )
            except StorageNotFound:
                return RPCResponse(request.id, error=NotFound())
            except StorageExpired:
                return RPCResponse(request.id, error=Expired())
            except StorageConflict as exc:
                return RPCResponse(request.id, error=Conflict(str(exc)))
            except ProtocolError as exc:
                return RPCResponse(request.id, error=exc)
        if operation.state == "ambiguous":
            if (
                request.method == "approval.respond"
                and approval_claim
                and approval_claim["retryable"]
            ):
                self.storage.retry_ambiguous_operation(device_id, request.op_id)
            else:
                return RPCResponse(
                    request.id, error=GatewayAmbiguous(details={"op_id": request.op_id})
                )
        if operation.state == "failed":
            return RPCResponse(
                request.id, error=self._stored_error(operation.error_code)
            )
        if operation.state == "executing":
            return RPCResponse(request.id, error=Conflict("Operation is in progress"))

        try:
            self.storage.mark_operation_executing(device_id, request.op_id)
            result = await self._execute(device_id, request)
            if request.method == "prompt.submit" and result.get("indeterminate"):
                self.storage.fail_operation(
                    device_id,
                    request.op_id,
                    ErrorCode.GATEWAY_AMBIGUOUS.value,
                    ambiguous=True,
                )
                return RPCResponse(request.id, error=GatewayAmbiguous())
            self.storage.complete_operation(device_id, request.op_id, result)
            return RPCResponse(request.id, result=result)
        except ProtocolError as exc:
            self.storage.fail_operation(device_id, request.op_id, exc.code.value)
            return RPCResponse(request.id, error=exc)
        except GatewayRPCError as exc:
            mapped = self._gateway_error(exc)
            self.storage.fail_operation(device_id, request.op_id, mapped.code.value)
            return RPCResponse(request.id, error=mapped)
        except (ConnectionError, TimeoutError):
            self.storage.fail_operation(
                device_id,
                request.op_id,
                ErrorCode.GATEWAY_AMBIGUOUS.value,
                ambiguous=True,
            )
            return RPCResponse(request.id, error=GatewayAmbiguous())
        except Exception:
            self.storage.fail_operation(
                device_id,
                request.op_id,
                ErrorCode.GATEWAY_AMBIGUOUS.value,
                ambiguous=True,
            )
            return RPCResponse(request.id, error=GatewayAmbiguous())

    async def _execute(self, device_id: str, request: RPCRequest) -> dict[str, Any]:
        p = request.params
        if request.method == "session.list":
            return {
                "sessions": await self.gateway.session_list(int(p.get("limit", 200)))
            }
        if request.method == "session.history":
            sid = self.storage.origin_session_id(p["session_id"])
            messages = await self.gateway.rest_history(sid)
            return {
                "session_id": sid,
                "messages": messages[: int(p.get("limit", 5000))],
            }
        if request.method == "session.open":
            sid = self.storage.origin_session_id(p["session_id"])
            # Store-read first; this does not reactivate or claim the session.
            history = await self.gateway.rest_history(sid)
            self.projection.import_gateway_history(sid, history)
            self.storage.set_subscription(device_id, sid, active=True, foreground=True)
            record = self.router.enqueue_checkpoint(device_id, sid)
            return {
                "session_id": sid,
                "origin_session_id": sid,
                "live_session_id": sid,
                "stream_id": self.storage.get_stream(device_id).stream_id,
                "checkpoint_through_seq": record.last_seq,
            }
        if request.method == "session.resume":
            origin = self.storage.origin_session_id(p["session_id"])
            result = await self.gateway.session_resume(origin)
            live = result.get("session_id") or origin
            self.storage.own_session(origin, live)
            self.storage.set_subscription(
                device_id, origin, active=True, foreground=True
            )
            return {
                "origin_session_id": origin,
                "live_session_id": live,
                "result": result,
            }
        if request.method == "prompt.submit":
            requested = p.get("session_id")
            origin = self.storage.origin_session_id(requested) if requested else None
            if origin is not None:
                live = self.storage.live_session_id(origin)
                if not self.gateway.owns(live):
                    resumed = await self.gateway.session_resume(origin)
                    live = resumed.get("session_id") or origin
                self.storage.own_session(origin, live)
            else:
                live = await self.gateway.session_create(
                    title=p.get("title") or "New chat",
                    model=p.get("model"),
                    provider=p.get("provider"),
                )
                origin = live
                self.storage.own_session(origin, live)
            # Gateway prompt submission starts the turn before its RPC resolves.
            # Persist the canonical origin subscription first so fast live-ID
            # start/delta/complete events cannot publish to an empty device set.
            # events cannot publish to an empty device set.  On an ambiguous
            # submit outcome the subscription remains active for the turn that
            # may already be running.
            self.storage.set_subscription(
                device_id, origin, active=True, foreground=True
            )
            user_ord = self.projection.next_ord(origin)
            try:
                self.projection.validate_user_message(
                    origin, p["client_message_id"], p["text"]
                )
            except ValueError as exc:
                raise Conflict("client_message_id request conflict") from exc
            # The Relay has durably received the user's message at this point.
            # Project and fan it out before invoking the Gateway, whose await
            # may synchronously emit the entire assistant turn.  This reserves
            # the transcript position and guarantees user-before-response live
            # ordering; a later Gateway failure is an operation error, not a
            # reason to erase what the user submitted.
            user_frame = self.projection.authoritative_user_frame(
                origin,
                p["client_message_id"],
                p["text"],
                ord_=user_ord,
            )
            self.router.publish_frames(
                origin,
                [user_frame],
                message_class=TransportClass.STATE,
            )
            result = await self.gateway.prompt_submit(
                live,
                p["text"],
                client_message_id=p["client_message_id"],
            )
            return {
                **result,
                "accepted": bool(result.get("accepted", True)),
                "client_message_id": p["client_message_id"],
                "origin_session_id": origin,
                "live_session_id": live,
            }
        if request.method == "session.interrupt":
            origin = self.storage.origin_session_id(p["session_id"])
            sid = self.storage.live_session_id(origin)
            return await self.gateway.session_interrupt(sid)
        if request.method == "approval.respond":
            decision = "once" if p["decision"] == "approve_once" else "deny"
            origin = self.storage.origin_session_id(p["session_id"])
            sid = self.storage.live_session_id(origin)
            assert request.op_id is not None
            try:
                result = await self.gateway.approval_respond(
                    sid, p["request_id"], decision, resolve_all=False
                )
            except GatewayRPCError as exc:
                if exc.code in {4009, 409}:
                    self.storage.resolve_approval_elsewhere(request_id=p["request_id"])
                else:
                    self.storage.fail_approval_capability(
                        capability=p["capability"],
                        device_id=device_id,
                        op_id=request.op_id,
                    )
                raise exc
            except (ConnectionError, TimeoutError):
                self.storage.mark_approval_retryable(
                    capability=p["capability"], device_id=device_id, op_id=request.op_id
                )
                raise
            except Exception:
                self.storage.mark_approval_retryable(
                    capability=p["capability"], device_id=device_id, op_id=request.op_id
                )
                raise
            self.storage.complete_approval_capability(
                capability=p["capability"], device_id=device_id, op_id=request.op_id
            )
            return result
        if request.method == "clarify.respond":
            origin = self.storage.origin_session_id(p["session_id"])
            sid = self.storage.live_session_id(origin)
            return await self.gateway.clarify_respond(sid, p["request_id"], p["text"])
        if request.method == "presence.set":
            if p["foreground"]:
                origin = self.storage.origin_session_id(p["session_id"])
                self.storage.set_subscription(
                    device_id, origin, active=True, foreground=True
                )
            else:
                self.storage.clear_presence(device_id)
            return {"ok": True}
        if request.method == "item.fetch":
            origin = self.storage.origin_session_id(p["session_id"])
            item = self.storage.session_item(origin, p["item_id"])
            if item is None:
                raise NotFound()
            return {"item": item}
        if request.method == "sync.request":
            stream = self.storage.get_stream(device_id)
            if p.get("stream_id") and p["stream_id"] != stream.stream_id:
                raise Conflict("stream_id mismatch")
            origin = self.storage.origin_session_id(p["session_id"])
            record = self.router.enqueue_checkpoint(device_id, origin)
            return {
                "stream_id": stream.stream_id,
                "checkpoint_through_seq": record.last_seq,
            }
        raise InvalidArgument("Unsupported RPC method")

    @staticmethod
    def _gateway_error(exc: GatewayRPCError) -> ProtocolError:
        if exc.code in {4001, 404}:
            return NotFound()
        if exc.code in {4009, 409}:
            return AlreadyResolved()
        if exc.code == 4091:
            return Conflict("client_message_id request conflict")
        return Conflict("Gateway rejected the operation")

    @staticmethod
    def _stored_error(code: str | None) -> ProtocolError:
        if code == ErrorCode.NOT_FOUND.value:
            return NotFound()
        if code == ErrorCode.ALREADY_RESOLVED.value:
            return AlreadyResolved()
        if code == ErrorCode.GATEWAY_AMBIGUOUS.value:
            return GatewayAmbiguous()
        return Conflict("Operation previously failed")


__all__ = [
    "RPCDispatcher",
    "RPCRequest",
    "RPCResponse",
    "SIDE_EFFECTING_METHODS",
    "SUPPORTED_METHODS",
    "validate_params",
]
