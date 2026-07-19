from __future__ import annotations

import asyncio
import hashlib
import hmac
import ipaddress
import json
import logging
import secrets
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response, WebSocket, WebSocketDisconnect, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError
from sqlalchemy.pool import StaticPool

from .crypto import (
    AuthorizationError,
    b64url_decode,
    b64url_encode,
    now_milliseconds,
    verify_activation_token_keyring,
    verify_envelope_signature,
    verify_grant_signature,
    verify_request_signature,
)
from .database_work import DatabaseBusy, DatabaseWorkPool
from .models import (
    AcknowledgementRequest,
    ActivationRequest,
    GrantRequest,
    OuterEnvelope,
    PairOfferAccept,
    PairOfferConfirm,
    PairOfferCreate,
    PairOfferMessage,
    PendingDeviceRoute,
    ProvisionalEnrollment,
)
from .settings import Settings
from .storage import (
    Conflict,
    DatabaseStore,
    EnrollmentRateLimited,
    Forbidden,
    MailboxFull,
    NotFound,
    ProvisionalCapacityExhausted,
)

logger = logging.getLogger("relay_hub")

_CLASS_LIMITS = {
    "realtime": 64 * 1024,
    "state": 256 * 1024,
    "command": 64 * 1024,
    "control": 32 * 1024,
}


def _error(code: str, http_status: int, message: str | None = None) -> HTTPException:
    return HTTPException(
        status_code=http_status,
        detail={"error": {"code": code, "message": message or code.replace("_", " ")}},
    )


def _no_store(response: Response) -> None:
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"


@dataclass(frozen=True)
class RoutePrincipal:
    route_id: str


class SocketCapacityExhausted(RuntimeError):
    pass


@dataclass(frozen=True)
class _SerializedSocketFrame:
    text: str
    wire_bytes: int
    overflow: bool = False


def _serialize_socket_frame(frame: dict, *, overflow: bool = False) -> _SerializedSocketFrame:
    # This exactly mirrors Starlette's WebSocket.send_json text encoding.
    text = json.dumps(frame, separators=(",", ":"), ensure_ascii=False)
    return _SerializedSocketFrame(
        text=text,
        wire_bytes=len(text.encode("utf-8")),
        overflow=overflow,
    )


_OVERFLOW_SOCKET_FRAME = _serialize_socket_frame(
    {"type": "overflow", "code": "reconnect_required"},
    overflow=True,
)


class SocketQueue:
    def __init__(self, manager: SocketManager, *, maxsize: int) -> None:
        self._manager = manager
        self._frames: asyncio.Queue[_SerializedSocketFrame] = asyncio.Queue(
            maxsize=maxsize
        )
        self._available = asyncio.Event()
        self._queued_bytes = 0
        self._registered = False
        self._overflowed = False

    async def get_serialized(self) -> _SerializedSocketFrame:
        return await self._manager._dequeue(self)

    async def get(self) -> dict:
        """Compatibility helper for manager-level tests and diagnostics."""

        return json.loads((await self.get_serialized()).text)


class SocketManager:
    def __init__(
        self,
        *,
        queue_depth: int,
        maximum_queue_bytes: int,
        maximum_total_queue_bytes: int,
        maximum_connections: int,
        maximum_connections_per_route: int,
    ) -> None:
        if queue_depth < 1:
            raise ValueError("socket queue depth must be positive")
        if maximum_connections < 1 or not (
            1 <= maximum_connections_per_route <= maximum_connections
        ):
            raise ValueError("invalid socket connection limits")
        if maximum_queue_bytes < _OVERFLOW_SOCKET_FRAME.wire_bytes:
            raise ValueError("per-socket queue byte limit cannot fit overflow frame")
        if (
            maximum_total_queue_bytes
            < maximum_connections * _OVERFLOW_SOCKET_FRAME.wire_bytes
        ):
            raise ValueError("global queue byte limit cannot fit socket control reserves")
        self._queue_depth = queue_depth
        self._maximum_queue_bytes = maximum_queue_bytes
        self._maximum_total_queue_bytes = maximum_total_queue_bytes
        self._maximum_connections = maximum_connections
        self._maximum_connections_per_route = maximum_connections_per_route
        self._connection_count = 0
        self._total_queued_bytes = 0
        self._reserved_overflow_bytes = 0
        self._queues: dict[str, set[SocketQueue]] = {}
        self._lock = asyncio.Lock()

    async def add(self, route_id: str) -> SocketQueue:
        queue = SocketQueue(self, maxsize=self._queue_depth)
        async with self._lock:
            route_queues = self._queues.get(route_id)
            if self._connection_count >= self._maximum_connections:
                raise SocketCapacityExhausted("global socket capacity exhausted")
            if (
                route_queues is not None
                and len(route_queues) >= self._maximum_connections_per_route
            ):
                raise SocketCapacityExhausted("route socket capacity exhausted")
            if (
                self._total_queued_bytes
                + self._reserved_overflow_bytes
                + _OVERFLOW_SOCKET_FRAME.wire_bytes
                > self._maximum_total_queue_bytes
            ):
                raise SocketCapacityExhausted("global socket byte capacity exhausted")
            self._queues.setdefault(route_id, set()).add(queue)
            self._connection_count += 1
            self._reserved_overflow_bytes += _OVERFLOW_SOCKET_FRAME.wire_bytes
            queue._registered = True
        return queue

    async def remove(self, route_id: str, queue: SocketQueue) -> None:
        async with self._lock:
            queues = self._queues.get(route_id)
            if queues is not None:
                if queue in queues:
                    queues.remove(queue)
                    self._connection_count -= 1
                    queue._registered = False
                    self._total_queued_bytes -= queue._queued_bytes
                    queue._queued_bytes = 0
                    if not queue._overflowed:
                        self._reserved_overflow_bytes -= (
                            _OVERFLOW_SOCKET_FRAME.wire_bytes
                        )
                    while True:
                        try:
                            queue._frames.get_nowait()
                        except asyncio.QueueEmpty:
                            break
                    # Wake any blocked consumer so it observes the terminal
                    # unregistered state instead of waiting forever.
                    queue._available.set()
                if not queues:
                    self._queues.pop(route_id, None)

    async def publish(self, route_id: str, envelope: dict) -> int:
        return await self.publish_frame(
            route_id,
            {"type": "message", "envelope": envelope},
            durable=envelope.get("class") != "realtime",
        )

    async def publish_frame(
        self, route_id: str, frame: dict, *, durable: bool = True
    ) -> int:
        serialized = _serialize_socket_frame(frame)
        async with self._lock:
            queues = tuple(self._queues.get(route_id, ()))
            delivered = 0
            for queue in queues:
                if queue._overflowed:
                    continue
                per_socket_bytes_exceeded = (
                    queue._queued_bytes
                    + serialized.wire_bytes
                    + _OVERFLOW_SOCKET_FRAME.wire_bytes
                    > self._maximum_queue_bytes
                )
                global_bytes_exceeded = (
                    self._total_queued_bytes
                    + self._reserved_overflow_bytes
                    + serialized.wire_bytes
                    > self._maximum_total_queue_bytes
                )
                if per_socket_bytes_exceeded or global_bytes_exceeded:
                    self._overflow_locked(queue)
                    continue
                if queue._frames.full():
                    if durable:
                        self._overflow_locked(queue)
                    continue
                queue._frames.put_nowait(serialized)
                queue._available.set()
                queue._queued_bytes += serialized.wire_bytes
                self._total_queued_bytes += serialized.wire_bytes
                delivered += 1
            return delivered

    def _overflow_locked(self, queue: SocketQueue) -> None:
        # The per-connection control reserve guarantees this signal always fits,
        # even when another queue currently owns the remaining data budget.
        self._total_queued_bytes -= queue._queued_bytes
        queue._queued_bytes = 0
        while True:
            try:
                queue._frames.get_nowait()
            except asyncio.QueueEmpty:
                break
        queue._frames.put_nowait(_OVERFLOW_SOCKET_FRAME)
        queue._available.set()
        queue._queued_bytes = _OVERFLOW_SOCKET_FRAME.wire_bytes
        self._total_queued_bytes += _OVERFLOW_SOCKET_FRAME.wire_bytes
        self._reserved_overflow_bytes -= _OVERFLOW_SOCKET_FRAME.wire_bytes
        queue._overflowed = True

    async def _dequeue(self, queue: SocketQueue) -> _SerializedSocketFrame:
        while True:
            await queue._available.wait()
            async with self._lock:
                if not queue._registered:
                    raise RuntimeError("socket queue is no longer registered")
                try:
                    frame = queue._frames.get_nowait()
                except asyncio.QueueEmpty:
                    queue._available.clear()
                    continue
                if queue._frames.empty():
                    queue._available.clear()
                queue._queued_bytes -= frame.wire_bytes
                self._total_queued_bytes -= frame.wire_bytes
                return frame

    async def queued_bytes(self, queue: SocketQueue | None = None) -> int:
        async with self._lock:
            if queue is None:
                return self._total_queued_bytes
            return queue._queued_bytes if queue._registered else 0

    async def is_online(self, route_id: str) -> bool:
        async with self._lock:
            return bool(self._queues.get(route_id))


def _enrollment_source_hash_key(settings: Settings) -> bytes:
    if settings.operator_enrollment_token:
        authority = b"operator\0" + settings.operator_enrollment_token.encode("utf-8")
    elif settings.activation_verification_keys:
        authority = b"activation\0" + b"".join(
            key_id.encode("ascii") + b"\0" + public_key
            for key_id, public_key in sorted(settings.activation_verification_keys)
        )
    else:
        # Public production mode always has an authority. Random development
        # keys deliberately avoid linkable source hashes across restarts.
        authority = b"development\0" + secrets.token_bytes(32)
    return hashlib.sha256(b"HRH2 enrollment rate source\0" + authority).digest()


def enrollment_source_hash(source: str | None, *, key: bytes) -> bytes | None:
    """Return a private stable bucket; IPv6 privacy addresses share a /64."""

    if source is None:
        return None
    source = source.strip()
    if not source or len(source.encode("utf-8")) > 255:
        return None
    address_text = source.split("%", 1)[0]
    try:
        address = ipaddress.ip_address(address_text)
    except ValueError:
        # ASGI test clients and Unix-socket servers may expose a trusted peer
        # name rather than an IP address. It is still server-provided input.
        canonical = b"host\0" + source.casefold().encode("utf-8")
    else:
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            canonical = b"ipv4\0" + address.ipv4_mapped.packed
        elif isinstance(address, ipaddress.IPv6Address):
            canonical = b"ipv6/64\0" + address.packed[:8]
        else:
            canonical = b"ipv4\0" + address.packed
    return hmac.new(key, canonical, hashlib.sha256).digest()


def create_app(
    *, settings: Settings | None = None, store: DatabaseStore | None = None
) -> FastAPI:
    settings = settings or Settings.from_env()
    settings.validate()
    store = store or DatabaseStore(settings)
    database_concurrency = (
        1
        if isinstance(store.engine.pool, StaticPool)
        else settings.database_max_concurrency
    )
    database = DatabaseWorkPool(
        max_concurrency=database_concurrency,
        acquire_timeout_seconds=settings.database_acquire_timeout_seconds,
    )
    sockets = SocketManager(
        queue_depth=settings.socket_queue_depth,
        maximum_queue_bytes=settings.effective_socket_queue_max_bytes,
        maximum_total_queue_bytes=settings.socket_queue_total_max_bytes,
        maximum_connections=settings.maximum_socket_connections,
        maximum_connections_per_route=settings.maximum_socket_connections_per_route,
    )
    source_hash_key = _enrollment_source_hash_key(settings)
    stop_purge = asyncio.Event()

    async def purge_loop() -> None:
        while not stop_purge.is_set():
            try:
                await asyncio.wait_for(stop_purge.wait(), timeout=60)
            except TimeoutError:
                try:
                    result = await database.run(store.purge, now_milliseconds())
                except DatabaseBusy:
                    logger.warning("expired opaque relay record purge deferred: database busy")
                    continue
                if any(result.values()):
                    logger.info("expired opaque relay records purged counts=%s", result)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        task = asyncio.create_task(purge_loop(), name="relay-hub-purge")
        try:
            yield
        finally:
            stop_purge.set()
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            await database.shutdown()

    app = FastAPI(title="Hermes Relay Hub", version="2", lifespan=lifespan)
    app.state.settings = settings
    app.state.store = store
    app.state.sockets = sockets
    app.state.database = database

    @app.middleware("http")
    async def request_body_limit(request: Request, call_next):
        maximum = settings.maximum_request_body_bytes
        content_length = request.headers.get("content-length")
        if content_length is not None:
            try:
                if int(content_length) > maximum:
                    return JSONResponse(
                        status_code=status.HTTP_413_CONTENT_TOO_LARGE,
                        content={
                            "error": {
                                "code": "request_body_too_large",
                                "message": "request body too large",
                            }
                        },
                    )
            except ValueError:
                return JSONResponse(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    content={
                        "error": {
                            "code": "invalid_content_length",
                            "message": "invalid content length",
                        }
                    },
                )
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > maximum:
                return JSONResponse(
                    status_code=status.HTTP_413_CONTENT_TOO_LARGE,
                    content={
                        "error": {
                            "code": "request_body_too_large",
                            "message": "request body too large",
                        }
                    },
                )
        request._body = bytes(body)
        return await call_next(request)

    @app.exception_handler(HTTPException)
    async def typed_http_error(_request: Request, exc: HTTPException) -> JSONResponse:
        content = exc.detail if isinstance(exc.detail, dict) and "error" in exc.detail else {
            "error": {"code": "request_failed", "message": "request failed"}
        }
        return JSONResponse(status_code=exc.status_code, content=content, headers=exc.headers)

    @app.exception_handler(RequestValidationError)
    async def typed_validation_error(_request: Request, _exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            content={"error": {"code": "invalid_request", "message": "invalid request"}},
        )

    @app.exception_handler(DatabaseBusy)
    async def database_busy(_request: Request, _exc: DatabaseBusy) -> JSONResponse:
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={
                "error": {
                    "code": "database_busy",
                    "message": "database busy",
                }
            },
            headers={"Retry-After": "1"},
        )

    async def authenticate_request(
        request: Request,
        *,
        expected_route: str | None = None,
        allow_provisional_agent: bool = False,
        allow_revoked_self_route: str | None = None,
    ) -> RoutePrincipal:
        route_id = request.headers.get("X-Hermes-Route", "")
        timestamp_text = request.headers.get("X-Hermes-Timestamp", "")
        nonce_text = request.headers.get("X-Hermes-Nonce", "")
        signature_text = request.headers.get("X-Hermes-Signature", "")
        if not all((route_id, timestamp_text, nonce_text, signature_text)):
            raise _error("route_auth_required", status.HTTP_401_UNAUTHORIZED)
        if expected_route is not None and route_id != expected_route:
            raise _error("route_auth_mismatch", status.HTTP_403_FORBIDDEN)
        try:
            timestamp_ms = int(timestamp_text)
            nonce = b64url_decode(nonce_text, field="request nonce", exact=16)
            signature = b64url_decode(signature_text, field="request signature", exact=64)
        except ValueError as exc:
            raise _error("invalid_route_auth", status.HTTP_401_UNAUTHORIZED) from exc
        now_ms = now_milliseconds()
        if abs(now_ms - timestamp_ms) > settings.request_clock_skew_seconds * 1000:
            raise _error("route_auth_expired", status.HTTP_401_UNAUTHORIZED)
        route = await database.run(store.get_route, route_id)
        provisional_allowed = (
            route is not None
            and allow_provisional_agent
            and route.status == "provisional"
            and route.route_type == "agent"
            and route.expires_at_ms is not None
            and route.expires_at_ms > now_ms
        )
        revoked_self_allowed = (
            route is not None
            and route.status == "revoked"
            and allow_revoked_self_route == route_id
        )
        if route is None or (
            route.status != "active"
            and not provisional_allowed
            and not revoked_self_allowed
        ):
            raise _error("route_not_active", status.HTTP_401_UNAUTHORIZED)
        body = await request.body()
        try:
            verify_request_signature(
                public_key=route.auth_public_key,
                signature=signature,
                method=request.method,
                path=request.url.path,
                route_id=route_id,
                timestamp_ms=timestamp_ms,
                nonce=nonce,
                body=body,
            )
        except AuthorizationError as exc:
            raise _error("invalid_route_auth", status.HTTP_401_UNAUTHORIZED) from exc
        if not await database.run(
            store.consume_request_nonce,
            route_id=route_id,
            nonce=nonce,
            expires_at_ms=now_ms + settings.request_clock_skew_seconds * 1000,
        ):
            raise _error("route_auth_replay", status.HTTP_409_CONFLICT)
        return RoutePrincipal(route_id)

    async def authenticate_socket(websocket: WebSocket) -> RoutePrincipal:
        route_id = websocket.headers.get("X-Hermes-Route", "")
        timestamp_text = websocket.headers.get("X-Hermes-Timestamp", "")
        nonce_text = websocket.headers.get("X-Hermes-Nonce", "")
        signature_text = websocket.headers.get("X-Hermes-Signature", "")
        try:
            timestamp_ms = int(timestamp_text)
            nonce = b64url_decode(nonce_text, field="request nonce", exact=16)
            signature = b64url_decode(signature_text, field="request signature", exact=64)
        except (ValueError, TypeError) as exc:
            raise AuthorizationError("invalid socket authorization headers") from exc
        now_ms = now_milliseconds()
        if abs(now_ms - timestamp_ms) > settings.request_clock_skew_seconds * 1000:
            raise AuthorizationError("socket authorization expired")
        route = await database.run(store.get_route, route_id)
        if route is None or route.status != "active":
            raise AuthorizationError("route not active")
        verify_request_signature(
            public_key=route.auth_public_key,
            signature=signature,
            method="GET",
            path="/v2/socket",
            route_id=route_id,
            timestamp_ms=timestamp_ms,
            nonce=nonce,
            body=b"",
        )
        if not await database.run(
            store.consume_request_nonce,
            route_id=route_id,
            nonce=nonce,
            expires_at_ms=now_ms + settings.request_clock_skew_seconds * 1000,
        ):
            raise AuthorizationError("socket authorization replay")
        return RoutePrincipal(route_id)

    async def accept_message(envelope: OuterEnvelope) -> tuple[dict, int]:
        now_ms = now_milliseconds()
        if envelope.src == envelope.dst:
            raise _error("same_route_forbidden", status.HTTP_403_FORBIDDEN)
        if envelope.expires_at_ms <= now_ms:
            raise _error("message_expired", status.HTTP_422_UNPROCESSABLE_CONTENT)
        if envelope.expires_at_ms > now_ms + settings.maximum_retention_seconds * 1000:
            raise _error("message_ttl_too_long", status.HTTP_422_UNPROCESSABLE_CONTENT)
        size_bytes = len(b64url_decode(envelope.enc, field="enc")) + len(
            b64url_decode(envelope.ct, field="ct")
        )
        if size_bytes > _CLASS_LIMITS[envelope.message_class]:
            raise _error("message_too_large", status.HTTP_413_CONTENT_TOO_LARGE)
        source = await database.run(store.get_route, envelope.src)
        if source is None or source.status not in {"active", "pending"}:
            raise _error("source_route_not_active", status.HTTP_403_FORBIDDEN)
        try:
            verify_envelope_signature(envelope, source.auth_public_key)
            result = await database.run(
                store.accept_envelope,
                envelope,
                now_ms=now_ms,
            )
        except AuthorizationError as exc:
            raise _error("invalid_envelope_signature", status.HTTP_401_UNAUTHORIZED) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        except MailboxFull as exc:
            raise _error(str(exc), status.HTTP_429_TOO_MANY_REQUESTS) from exc
        wire = envelope.model_dump(by_alias=True)
        delivered = await sockets.publish(envelope.dst, wire)
        mid_hash = hashlib.sha256(b64url_decode(envelope.mid, field="mid")).hexdigest()[:12]
        logger.info(
            "opaque envelope accepted mid_hash=%s class=%s bytes=%d stored=%s live_receivers=%d deduplicated=%s",
            mid_hash,
            envelope.message_class,
            size_bytes,
            result.stored,
            delivered,
            result.deduplicated,
        )
        return {
            "accepted": True,
            "deduplicated": result.deduplicated,
            "stored": result.stored,
            "mid": envelope.mid,
        }, status.HTTP_200_OK if result.deduplicated else status.HTTP_202_ACCEPTED

    @app.get("/healthz")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/readyz")
    async def ready(response: Response) -> dict[str, str]:
        try:
            is_ready = await database.run(store.ready)
        except DatabaseBusy:
            is_ready = False
        if not is_ready:
            response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
            return {"status": "not_ready"}
        return {"status": "ready"}

    @app.get("/v2/route-proof")
    async def route_proof(request: Request, response: Response) -> dict[str, str]:
        """Content-free signed ownership proof for active/provisional Agents."""

        principal = await authenticate_request(
            request, allow_provisional_agent=True
        )
        route = await database.run(store.get_route, principal.route_id)
        if route is None or route.status not in {"provisional", "active"}:
            raise _error("route_not_active", status.HTTP_401_UNAUTHORIZED)
        _no_store(response)
        return {"route_id": principal.route_id, "status": route.status}

    @app.post("/v2/enroll/provisional", status_code=status.HTTP_201_CREATED)
    async def provisional(
        body: ProvisionalEnrollment,
        request: Request,
        response: Response,
    ) -> dict[str, Any]:
        now_ms = now_milliseconds()
        public_key = b64url_decode(
            body.auth_public_key, field="auth_public_key", exact=32
        )
        source_hash = enrollment_source_hash(
            request.client.host if request.client is not None else None,
            key=source_hash_key,
        )
        if source_hash is None:
            raise _error("provisional_enrollment_rate_limited", status.HTTP_429_TOO_MANY_REQUESTS)
        route_id = "rte_" + b64url_encode(secrets.token_bytes(24))
        expires_at_ms = now_ms + settings.provisional_ttl_seconds * 1000
        try:
            result = await database.run(
                store.create_provisional,
                enrollment_id=body.enrollment_id,
                route_id=route_id,
                public_key=public_key,
                route_type=body.route_type,
                source_hash=source_hash,
                now_ms=now_ms,
                expires_at_ms=expires_at_ms,
            )
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        except EnrollmentRateLimited as exc:
            raise _error(
                str(exc), status.HTTP_429_TOO_MANY_REQUESTS
            ) from exc
        except ProvisionalCapacityExhausted as exc:
            raise _error(
                str(exc), status.HTTP_503_SERVICE_UNAVAILABLE
            ) from exc
        if not result.created:
            response.status_code = status.HTTP_200_OK
        return {
            "enrollment_id": body.enrollment_id,
            "route_id": result.route_id,
            "status": "provisional",
            "expires_at_ms": result.expires_at_ms,
        }

    @app.post("/v2/enroll/activate")
    async def activate(body: ActivationRequest, request: Request) -> dict[str, Any]:
        now_ms = now_milliseconds()
        operator = request.headers.get("X-Hermes-Enrollment-Token")
        development = request.headers.get("X-Hermes-Development-Token")
        token_hash: bytes | None = None
        if settings.operator_enrollment_token and operator and secrets.compare_digest(
            settings.operator_enrollment_token, operator
        ):
            token_hash = hashlib.sha256(f"operator:{body.route_id}:{operator}".encode()).digest()
        elif settings.development_activation_token and development and secrets.compare_digest(
            settings.development_activation_token, development
        ):
            token_hash = hashlib.sha256(f"development:{body.route_id}:{development}".encode()).digest()
        elif settings.activation_verification_keys and body.activation_token:
            try:
                claims = verify_activation_token_keyring(
                    body.activation_token,
                    dict(settings.activation_verification_keys),
                    expected_route=body.route_id,
                    now_ms=now_ms,
                )
            except AuthorizationError as exc:
                raise _error("invalid_activation_token", status.HTTP_401_UNAUTHORIZED) from exc
            token_hash = hashlib.sha256((claims.token_id + ":" + body.activation_token).encode()).digest()
        if token_hash is None:
            raise _error("activation_authorization_required", status.HTTP_401_UNAUTHORIZED)
        try:
            changed = await database.run(
                store.activate_route,
                route_id=body.route_id,
                token_hash=token_hash,
                now_ms=now_ms,
            )
        except NotFound as exc:
            raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        return {"route_id": body.route_id, "status": "active", "already_active": not changed}

    @app.post("/v2/grants", status_code=status.HTTP_201_CREATED)
    async def create_grant(body: GrantRequest, request: Request, response: Response) -> dict[str, Any]:
        principal = await authenticate_request(request, expected_route=body.issuer_route)
        _no_store(response)
        if principal.route_id not in {body.source_route, body.destination_route}:
            raise _error("grant_issuer_not_party", status.HTTP_403_FORBIDDEN)
        issuer = await database.run(store.get_route, body.issuer_route)
        if issuer is None or issuer.route_type != "agent":
            raise _error("grant_issuer_must_be_agent", status.HTTP_403_FORBIDDEN)
        now_ms = now_milliseconds()
        if body.expires_at_ms is not None and body.expires_at_ms <= now_ms:
            raise _error("grant_expired", status.HTTP_422_UNPROCESSABLE_CONTENT)
        try:
            verify_grant_signature(body, issuer.auth_public_key)
            created = await database.run(
                store.create_grant,
                body,
                now_ms=now_ms,
            )
        except AuthorizationError as exc:
            raise _error("invalid_grant_signature", status.HTTP_401_UNAUTHORIZED) from exc
        except NotFound as exc:
            raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        if not created:
            response.status_code = status.HTTP_200_OK
        grant_status = await database.run(store.get_grant_status, body.grant_id)
        return {
            "grant_id": body.grant_id,
            "created": created,
            "status": grant_status,
        }

    @app.post("/v2/routes", status_code=status.HTTP_201_CREATED)
    async def create_pending_route(
        body: PendingDeviceRoute, request: Request, response: Response
    ) -> dict[str, Any]:
        principal = await authenticate_request(request)
        _no_store(response)
        proposed_route_id = "rte_" + b64url_encode(secrets.token_bytes(24))
        try:
            route_id, created = await database.run(
                store.create_pending_device,
                route_id=proposed_route_id,
                public_key=b64url_decode(body.auth_public_key, field="auth_public_key", exact=32),
                owner_route=principal.route_id,
                offer_id=body.offer_id,
                now_ms=now_milliseconds(),
            )
        except NotFound as exc:
            raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        if not created:
            response.status_code = status.HTTP_200_OK
        return {
            "route_id": route_id,
            "status": "pending",
            "owner_route": principal.route_id,
            "offer_id": body.offer_id,
        }

    @app.delete("/v2/grants/{grant_id}")
    async def delete_grant(grant_id: str, request: Request) -> dict[str, Any]:
        principal = await authenticate_request(request)
        try:
            changed = await database.run(
                store.revoke_grant,
                grant_id=grant_id,
                actor_route=principal.route_id,
                now_ms=now_milliseconds(),
            )
        except NotFound as exc:
            raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        return {"grant_id": grant_id, "revoked": True, "already_revoked": not changed}

    @app.post("/v2/messages")
    async def post_message(body: OuterEnvelope, response: Response) -> dict[str, Any]:
        result, response.status_code = await accept_message(body)
        return result

    @app.post("/v2/acks")
    async def acknowledge(body: AcknowledgementRequest, request: Request) -> dict[str, Any]:
        principal = await authenticate_request(request)
        count = await database.run(
            store.acknowledge,
            route_id=principal.route_id,
            message_ids=[b64url_decode(value, field="message_id", exact=16) for value in body.message_ids],
        )
        return {"acknowledged": count}

    @app.post("/v2/offers", status_code=status.HTTP_201_CREATED)
    async def create_offer(
        body: PairOfferCreate, request: Request, response: Response
    ) -> dict[str, Any]:
        principal = await authenticate_request(
            request,
            expected_route=body.owner_route,
            allow_provisional_agent=True,
        )
        _no_store(response)
        now_ms = now_milliseconds()
        if body.expires_at_ms <= now_ms or body.expires_at_ms > now_ms + 600_000:
            raise _error("pair_offer_expiry_invalid", status.HTTP_422_UNPROCESSABLE_CONTENT)
        try:
            created = await database.run(
                store.create_pair_offer,
                offer_id=body.offer_id,
                offer_route=body.offer_route,
                owner_route=principal.route_id,
                token_hash=b64url_decode(
                    body.transport_token_hash, field="transport_token_hash", exact=32
                ),
                expires_at_ms=body.expires_at_ms,
                now_ms=now_ms,
            )
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        except MailboxFull as exc:
            raise _error(str(exc), status.HTTP_429_TOO_MANY_REQUESTS) from exc
        if not created:
            response.status_code = status.HTTP_200_OK
        return {
            "offer_id": body.offer_id,
            "offer_route": body.offer_route,
            "expires_at_ms": body.expires_at_ms,
        }

    @app.post("/v2/offers/{offer_route}/messages")
    async def submit_offer_message(
        offer_route: str, body: PairOfferMessage, request: Request, response: Response
    ) -> dict[str, Any]:
        _no_store(response)
        authorization = request.headers.get("Authorization", "")
        if not authorization.startswith("Bearer "):
            raise _error("pair_transport_token_required", status.HTTP_401_UNAUTHORIZED)
        try:
            raw_token = b64url_decode(
                authorization.removeprefix("Bearer "), field="pair transport token", exact=32
            )
            deduplicated, owner_route, wire = await database.run(
                store.submit_pair_message,
                offer_route=offer_route,
                offer_id=body.offer_id,
                token_hash=hashlib.sha256(raw_token).digest(),
                enc=b64url_decode(body.enc, field="enc", exact=32),
                ciphertext=b64url_decode(body.ct, field="ct", maximum=32 * 1024),
                now_ms=now_milliseconds(),
            )
        except ValueError as exc:
            raise _error("pair_transport_token_invalid", status.HTTP_401_UNAUTHORIZED) from exc
        except NotFound as exc:
            raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        if deduplicated:
            response.status_code = status.HTTP_200_OK
        else:
            response.status_code = status.HTTP_202_ACCEPTED
            await sockets.publish_frame(owner_route, {"type": "offer", "offer": wire})
        return {"accepted": True, "deduplicated": deduplicated, "offer_id": body.offer_id}

    @app.get("/v2/offers/{offer_id}")
    async def get_offer(
        offer_id: str, request: Request, response: Response
    ) -> dict[str, Any]:
        principal = await authenticate_request(
            request, allow_provisional_agent=True
        )
        _no_store(response)
        try:
            return await database.run(
                store.get_pair_offer,
                offer_id=offer_id,
                owner_route=principal.route_id,
                now_ms=now_milliseconds(),
            )
        except NotFound as exc:
            raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc

    @app.post("/v2/offers/{offer_id}/accept")
    async def accept_offer(
        offer_id: str,
        body: PairOfferAccept,
        request: Request,
        response: Response,
    ) -> dict[str, Any]:
        principal = await authenticate_request(request)
        _no_store(response)
        try:
            _deduplicated, response_hash = await database.run(
                store.accept_pair_offer,
                offer_id=offer_id,
                owner_route=principal.route_id,
                message_hash=b64url_decode(body.message_hash, field="message_hash", exact=32),
                device_route=body.device_route,
                enc=b64url_decode(body.enc, field="enc", exact=32),
                ciphertext=b64url_decode(body.ct, field="ct", maximum=32 * 1024),
                now_ms=now_milliseconds(),
            )
        except NotFound as exc:
            raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        return {
            "status": "accepted",
            "offer_id": offer_id,
            "device_route": body.device_route,
            "response_hash": b64url_encode(response_hash),
        }

    @app.get("/v2/offers/{offer_route}/accept")
    async def get_offer_accept(
        offer_route: str, request: Request, response: Response
    ) -> dict[str, Any]:
        _no_store(response)
        authorization = request.headers.get("Authorization", "")
        if not authorization.startswith("Bearer "):
            raise _error("pair_transport_token_required", status.HTTP_401_UNAUTHORIZED)
        try:
            raw_token = b64url_decode(
                authorization.removeprefix("Bearer "),
                field="pair transport token",
                exact=32,
            )
            return await database.run(
                store.get_pair_accept,
                offer_route=offer_route,
                token_hash=hashlib.sha256(raw_token).digest(),
                now_ms=now_milliseconds(),
            )
        except ValueError as exc:
            raise _error("pair_transport_token_invalid", status.HTTP_401_UNAUTHORIZED) from exc
        except NotFound as exc:
            raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc

    @app.post("/v2/offers/{offer_id}/confirm")
    async def confirm_offer(
        offer_id: str,
        body: PairOfferConfirm,
        request: Request,
        response: Response,
    ) -> dict[str, Any]:
        principal = await authenticate_request(request)
        _no_store(response)
        try:
            grant_ids = await database.run(
                store.confirm_pair_offer,
                offer_id=offer_id,
                owner_route=principal.route_id,
                message_hash=b64url_decode(body.message_hash, field="message_hash", exact=32),
                response_hash=b64url_decode(body.response_hash, field="response_hash", exact=32),
                device_route=body.device_route,
                now_ms=now_milliseconds(),
            )
        except NotFound as exc:
            raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        return {
            "device_route": body.device_route,
            "status": "active",
            "grant_ids": grant_ids,
        }

    @app.delete("/v2/offers/{offer_id}/cancel")
    async def cancel_offer(
        offer_id: str, request: Request, response: Response
    ) -> dict[str, Any]:
        principal = await authenticate_request(
            request, allow_provisional_agent=True
        )
        _no_store(response)
        try:
            deleted = await database.run(
                store.cancel_pair_offer,
                offer_id=offer_id,
                owner_route=principal.route_id,
                now_ms=now_milliseconds(),
            )
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        return {"offer_id": offer_id, "deleted": deleted}

    @app.delete("/v2/routes/{route_id}")
    async def delete_route(route_id: str, request: Request) -> dict[str, Any]:
        # A route may retry its own DELETE after the first 200 response was
        # lost. This is the only endpoint where its tombstoned verification
        # key remains usable; it cannot authorize any other route or action.
        principal = await authenticate_request(
            request, allow_revoked_self_route=route_id
        )
        try:
            changed, grant_ids = await database.run(
                store.revoke_route,
                route_id=route_id,
                actor_route=principal.route_id,
                now_ms=now_milliseconds(),
            )
        except NotFound as exc:
            raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        return {
            "route_id": route_id,
            "status": "revoked",
            "grant_ids": grant_ids,
            "already_revoked": not changed,
        }

    @app.websocket("/v2/socket")
    async def socket(websocket: WebSocket) -> None:
        try:
            principal = await authenticate_socket(websocket)
        except DatabaseBusy:
            await websocket.accept()
            await websocket.close(code=1013, reason="database busy")
            return
        except AuthorizationError:
            await websocket.close(code=4401, reason="route authorization failed")
            return
        try:
            queue = await sockets.add(principal.route_id)
        except SocketCapacityExhausted:
            await websocket.accept()
            await websocket.close(code=1013, reason="socket capacity exhausted")
            return
        try:
            await websocket.accept()
        except BaseException:
            await sockets.remove(principal.route_id, queue)
            raise

        async def sender() -> None:
            try:
                pending = await database.run(
                    store.pending_envelopes,
                    route_id=principal.route_id,
                    now_ms=now_milliseconds(),
                )
            except DatabaseBusy:
                await websocket.send_json({"type": "error", "code": "database_busy"})
                await websocket.close(code=1013, reason="database busy")
                return
            for envelope in pending:
                await websocket.send_json({"type": "message", "envelope": envelope})
            while True:
                frame = await queue.get_serialized()
                await websocket.send_text(frame.text)
                if frame.overflow:
                    await websocket.close(code=1013, reason="mailbox replay required")
                    return

        send_task = asyncio.create_task(sender(), name="relay-hub-socket-sender")
        try:
            while True:
                incoming = await websocket.receive_json()
                if not isinstance(incoming, dict):
                    await websocket.send_json({"type": "error", "code": "invalid_socket_frame"})
                    continue
                frame_type = incoming.get("type")
                if frame_type == "ping":
                    await websocket.send_json({"type": "pong"})
                elif frame_type == "ack":
                    try:
                        ack = AcknowledgementRequest.model_validate(
                            {"message_ids": incoming.get("message_ids")}
                        )
                    except ValidationError:
                        await websocket.send_json({"type": "error", "code": "invalid_ack"})
                        continue
                    try:
                        count = await database.run(
                            store.acknowledge,
                            route_id=principal.route_id,
                            message_ids=[
                                b64url_decode(value, field="message_id", exact=16)
                                for value in ack.message_ids
                            ],
                        )
                    except DatabaseBusy:
                        await websocket.send_json(
                            {"type": "error", "code": "database_busy"}
                        )
                        continue
                    await websocket.send_json({"type": "acknowledged", "count": count})
                elif frame_type == "message":
                    try:
                        envelope = OuterEnvelope.model_validate(incoming.get("envelope"))
                        if envelope.src != principal.route_id:
                            raise ValueError("source route mismatch")
                        result, _ = await accept_message(envelope)
                        await websocket.send_json({"type": "accepted", **result})
                    except (ValidationError, ValueError):
                        await websocket.send_json({"type": "error", "code": "invalid_envelope"})
                    except HTTPException as exc:
                        detail = exc.detail if isinstance(exc.detail, dict) else {}
                        code = detail.get("error", {}).get("code", "message_rejected")
                        await websocket.send_json({"type": "error", "code": code})
                    except DatabaseBusy:
                        await websocket.send_json(
                            {"type": "error", "code": "database_busy"}
                        )
                else:
                    await websocket.send_json({"type": "error", "code": "unknown_socket_frame"})
        except WebSocketDisconnect:
            pass
        finally:
            send_task.cancel()
            await asyncio.gather(send_task, return_exceptions=True)
            await sockets.remove(principal.route_id, queue)

    return app
