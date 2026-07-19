from __future__ import annotations

import asyncio
import hashlib
import ipaddress
import json
import logging
import math
import secrets
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .apns import APNsClient, APNsEndpoint, APNsResult, PayloadTooLarge, build_payload
from .attestation import (
    AppleAppAttestVerifier,
    AttestationError,
    AttestationIdentity,
    AttestationVerifier,
)
from .crypto import (
    TokenVault,
    app_attest_key_hash,
    b64url_decode,
    b64url_encode,
    delivery_identifiers,
    hub_activation_transcript,
    mint_hub_activation_token,
    opaque_hash,
    registration_transcript,
    secret_hash,
)
from .models import (
    BindingExchange,
    BindingExchangeRevoke,
    EndpointRegistration,
    EndpointTokenRefresh,
    HubActivationRequest,
    SendRequest,
)
from .settings import Settings
from .storage import Conflict, DatabaseStore, Forbidden, NotFound, RateLimited
from .work_pool import BoundedWorkPool, WorkPoolSaturated

logger = logging.getLogger("push_gateway")
_ALL_CLASSES = frozenset({"update", "approval", "error"})


def _now_ms() -> int:
    import time

    return time.time_ns() // 1_000_000


def _error(
    code: str, http_status: int, *, headers: dict[str, str] | None = None
) -> HTTPException:
    return HTTPException(
        status_code=http_status,
        detail={"error": {"code": code, "message": code.replace("_", " ")}},
        headers=headers,
    )


def _no_store(response: Response) -> None:
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"


def _canonical_model_hash(body: Any) -> bytes:
    return hashlib.sha256(
        json.dumps(
            body.model_dump(by_alias=True),
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).digest()


def _bearer(request: Request) -> str:
    authorization = request.headers.get("Authorization", "")
    if not authorization.startswith("Bearer "):
        raise _error("send_capability_required", status.HTTP_401_UNAUTHORIZED)
    capability = authorization.removeprefix("Bearer ")
    if len(capability) < 32 or len(capability) > 200:
        raise _error("send_capability_invalid", status.HTTP_401_UNAUTHORIZED)
    return capability


def _canonical_source(host: str | None) -> str:
    """Aggregate privacy-address variants without trusting forwarding headers."""

    if not host:
        return "unknown"
    candidate = host.strip()
    if candidate.startswith("[") and candidate.endswith("]"):
        candidate = candidate[1:-1]
    # Zone identifiers are local routing details and must not create new quota
    # buckets.  They are not expected on public peer addresses, but normalize
    # them fail-closed if an ASGI server supplies one.
    candidate = candidate.split("%", 1)[0]
    try:
        address = ipaddress.ip_address(candidate)
    except ValueError:
        return "unknown"
    if isinstance(address, ipaddress.IPv6Address):
        mapped = address.ipv4_mapped
        if mapped is not None:
            return mapped.compressed
        network = ipaddress.IPv6Network((address, 64), strict=False)
        return f"{network.network_address.compressed}/64"
    return address.compressed


class _AttestationGate:
    """Non-queuing process-local bound for CPU-heavy verifier work."""

    def __init__(self, limit: int) -> None:
        self._limit = limit
        self._active = 0
        self._lock = asyncio.Lock()

    async def try_acquire(self) -> bool:
        async with self._lock:
            if self._active >= self._limit:
                return False
            self._active += 1
            return True

    async def release(self) -> None:
        async with self._lock:
            if self._active <= 0:
                raise RuntimeError("attestation gate released without an owner")
            self._active -= 1


def create_app(
    *,
    settings: Settings | None = None,
    store: DatabaseStore | None = None,
    verifier: AttestationVerifier | None = None,
    apns_sender: Any | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    settings.validate()
    store = store or DatabaseStore(settings)
    vault = TokenVault(
        settings.token_keyring,
        current_version=settings.token_key_version,
    )
    if store.ready():
        store.assert_token_keys_available(vault.available_versions)
    if verifier is None and settings.apple_app_id:
        verifier = AppleAppAttestVerifier(
            app_id=settings.apple_app_id,
            production=settings.app_attest_production,
            allow_development=settings.allow_development_attestation,
        )
    sender_holder: dict[str, Any | None] = {"sender": apns_sender}
    stop_purge = asyncio.Event()
    attestation_gate = _AttestationGate(settings.attestation_max_concurrency)
    database_pool = BoundedWorkPool(
        settings.database_max_concurrency,
        thread_name_prefix="push-gateway-db",
    )

    async def database_call(function, /, *args, **kwargs):
        try:
            return await database_pool.run(function, *args, **kwargs)
        except WorkPoolSaturated as exc:
            raise _error(
                "database_capacity_exhausted",
                status.HTTP_503_SERVICE_UNAVAILABLE,
                headers={"Retry-After": "1"},
            ) from exc

    async def purge_loop() -> None:
        while not stop_purge.is_set():
            try:
                await asyncio.wait_for(stop_purge.wait(), timeout=60)
            except TimeoutError:
                try:
                    result = await database_pool.run(store.purge, _now_ms())
                except WorkPoolSaturated:
                    logger.warning("push metadata purge deferred: database pool busy")
                    continue
                if any(result.values()):
                    logger.info("expired push metadata purged counts=%s", result)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        client: httpx.AsyncClient | None = None
        if sender_holder["sender"] is None and settings.apns_configured:
            client = httpx.AsyncClient(http2=True, timeout=httpx.Timeout(10))
            sender_holder["sender"] = APNsClient(settings, client=client)
        purge_task = asyncio.create_task(purge_loop(), name="push-gateway-purge")
        try:
            yield
        finally:
            stop_purge.set()
            purge_task.cancel()
            await asyncio.gather(purge_task, return_exceptions=True)
            if client is not None:
                await client.aclose()
            await database_pool.close()

    app = FastAPI(title="Hermes Push Gateway", version="2", lifespan=lifespan)
    app.state.settings = settings
    app.state.store = store
    app.state.token_vault = vault
    app.state.attestation_gate = attestation_gate
    app.state.database_pool = database_pool

    @app.middleware("http")
    async def request_body_limit(request: Request, call_next):
        maximum = 128 * 1024
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
        content = (
            exc.detail
            if isinstance(exc.detail, dict) and "error" in exc.detail
            else {"error": {"code": "request_failed", "message": "request failed"}}
        )
        return JSONResponse(
            status_code=exc.status_code, content=content, headers=exc.headers
        )

    @app.exception_handler(RequestValidationError)
    async def typed_validation_error(
        _request: Request, _exc: RequestValidationError
    ) -> JSONResponse:
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            content={
                "error": {"code": "invalid_request", "message": "invalid request"}
            },
        )

    def key_hash(key_id: str) -> bytes:
        return app_attest_key_hash(key_id, settings.capability_pepper)

    def development_attestation_authorized(request: Request) -> bool:
        token = request.headers.get("X-Hermes-Development-Token", "")
        return bool(
            settings.development_registration_token
            and secrets.compare_digest(token, settings.development_registration_token)
        )

    def verify_attested_request(
        *,
        request: Request,
        key_id: str,
        assertion: str,
        attestation: str | None,
        transcript: bytes,
        digest: bytes,
        bundle_id: str,
        environment: str,
        existing_public_key_der: bytes | None,
        existing_counter: int | None,
    ) -> AttestationIdentity:
        if development_attestation_authorized(request):
            return AttestationIdentity(
                public_key_der=b"hermes-explicit-development-attestation-v1",
                counter=(existing_counter or 0) + 1,
            )
        if verifier is None:
            raise _error("app_attest_unavailable", status.HTTP_503_SERVICE_UNAVAILABLE)
        try:
            return verifier.verify(
                key_id=key_id,
                assertion=assertion,
                attestation=attestation,
                request_transcript=transcript,
                request_hash=digest,
                bundle_id=bundle_id,
                environment=environment,
                existing_public_key_der=existing_public_key_der,
            )
        except AttestationError as exc:
            raise _error("app_attest_rejected", status.HTTP_403_FORBIDDEN) from exc

    async def reserve_attestation(
        *, challenge_hash: bytes, request_hash: bytes
    ) -> bytes | None:
        """Acquire crypto ownership, or observe one exact completed request."""

        deadline = asyncio.get_running_loop().time() + 5.0
        while True:
            try:
                reservation = await database_call(
                    store.reserve_attestation_validation,
                    challenge_hash=challenge_hash,
                    request_hash=request_hash,
                    now_ms=_now_ms(),
                )
            except Forbidden as exc:
                raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
            except Conflict as exc:
                raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
            if reservation.status == "acquired":
                assert reservation.owner_token is not None
                return reservation.owner_token
            if reservation.status == "completed":
                return None
            if reservation.status != "in_progress":
                raise RuntimeError("unknown attestation reservation state")
            if asyncio.get_running_loop().time() >= deadline:
                raise _error(
                    "attest_validation_in_progress",
                    status.HTTP_425_TOO_EARLY,
                    headers={"Retry-After": "1"},
                )
            await asyncio.sleep(0.05)

    async def release_attestation(*, challenge_hash: bytes, owner_token: bytes) -> None:
        # Shield the durable release from client cancellation. It contains no
        # credential material and conditionally matches this exact owner.
        release_task = asyncio.create_task(
            database_call(
                store.release_attestation_validation,
                challenge_hash=challenge_hash,
                owner_token=owner_token,
            )
        )
        try:
            await asyncio.shield(release_task)
        except asyncio.CancelledError:
            await release_task
            raise

    async def run_attestation_verifier(**kwargs: Any) -> AttestationIdentity:
        if not await attestation_gate.try_acquire():
            raise _error(
                "app_attest_capacity_exhausted",
                status.HTTP_429_TOO_MANY_REQUESTS,
                headers={"Retry-After": "1"},
            )
        task = asyncio.create_task(asyncio.to_thread(verify_attested_request, **kwargs))
        try:
            try:
                return await asyncio.shield(task)
            except asyncio.CancelledError:
                # A cancelled asyncio future cannot stop native x509/ECDSA
                # work. Keep its concurrency slot and durable challenge fence
                # until that worker really exits.
                await task
                raise
        finally:
            await attestation_gate.release()

    @app.get("/healthz")
    async def health() -> dict[str, Any]:
        return {"status": "ok", "apns_configured": settings.apns_configured}

    @app.get("/readyz")
    async def ready(response: Response) -> dict[str, str]:
        if not await database_call(store.ready) or (
            settings.require_apns and sender_holder["sender"] is None
        ):
            response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
            return {"status": "not_ready"}
        return {"status": "ready"}

    @app.get("/v2/attest/challenge")
    async def challenge(request: Request, response: Response) -> dict[str, Any]:
        _no_store(response)
        raw = b64url_encode(secrets.token_bytes(32))
        now_ms = _now_ms()
        expires_at_ms = now_ms + settings.challenge_ttl_seconds * 1000
        source = _canonical_source(
            request.client.host if request.client is not None else None
        )
        try:
            await database_call(
                store.issue_challenge,
                challenge_hash=secret_hash(raw, settings.capability_pepper),
                source_hash=opaque_hash(source, settings.capability_pepper),
                now_ms=now_ms,
                expires_at_ms=expires_at_ms,
            )
        except RateLimited as exc:
            headers = None
            if exc.retry_after_ms is not None:
                headers = {
                    "Retry-After": str(max(1, math.ceil(exc.retry_after_ms / 1000)))
                }
            raise _error(
                str(exc), status.HTTP_429_TOO_MANY_REQUESTS, headers=headers
            ) from exc
        return {"challenge": raw, "expires_at_ms": expires_at_ms}

    @app.post("/v2/hub-activations", status_code=status.HTTP_201_CREATED)
    async def hub_activation(
        body: HubActivationRequest, request: Request, response: Response
    ) -> dict[str, Any]:
        _no_store(response)
        if body.bundle_id not in settings.allowed_bundle_ids:
            raise _error("bundle_not_allowed", status.HTTP_403_FORBIDDEN)
        if settings.hub_activation_private_key is None:
            raise _error(
                "hub_activation_unavailable", status.HTTP_503_SERVICE_UNAVAILABLE
            )
        transcript = hub_activation_transcript(
            challenge=body.challenge,
            hub_route_id=body.hub_route_id,
            bundle_id=body.bundle_id,
            environment=body.environment,
            installation_nonce=body.installation_nonce,
        )
        digest = hashlib.sha256(transcript).digest()
        key_id_hash = key_hash(body.app_attest_key_id)
        challenge_hash = secret_hash(body.challenge, settings.capability_pepper)
        request_hash = _canonical_model_hash(body)
        now_ms = _now_ms()
        try:
            prior = await database_call(
                store.get_hub_activation_receipt,
                challenge_hash=challenge_hash,
                request_hash=request_hash,
                key_id_hash=key_id_hash,
                now_ms=now_ms,
            )
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        if prior is not None:
            response.status_code = status.HTTP_200_OK
            return json.loads(
                vault.decrypt(
                    prior.encrypted_response,
                    endpoint_id=prior.route_id,
                    bundle_id=prior.bundle_id,
                    environment=prior.environment,
                )
            )
        reservation_token = await reserve_attestation(
            challenge_hash=challenge_hash, request_hash=request_hash
        )
        if reservation_token is None:
            try:
                prior = await database_call(
                    store.get_hub_activation_receipt,
                    challenge_hash=challenge_hash,
                    request_hash=request_hash,
                    key_id_hash=key_id_hash,
                    now_ms=_now_ms(),
                )
            except Conflict as exc:
                raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
            if prior is None:
                raise _error(
                    "hub_activation_receipt_unavailable", status.HTTP_409_CONFLICT
                )
            response.status_code = status.HTTP_200_OK
            return json.loads(
                vault.decrypt(
                    prior.encrypted_response,
                    endpoint_id=prior.route_id,
                    bundle_id=prior.bundle_id,
                    environment=prior.environment,
                )
            )

        committed = False
        try:
            existing_key = await database_call(store.get_attest_key, key_id_hash)
            if (
                existing_key is None
                and body.attestation is None
                and not development_attestation_authorized(request)
            ):
                raise _error("app_attest_initial_required", status.HTTP_409_CONFLICT)
            identity = await run_attestation_verifier(
                request=request,
                key_id=body.app_attest_key_id,
                assertion=body.assertion,
                attestation=body.attestation,
                transcript=transcript,
                digest=digest,
                bundle_id=body.bundle_id,
                environment=body.environment,
                existing_public_key_der=(
                    existing_key.public_key_der if existing_key else None
                ),
                existing_counter=existing_key.counter if existing_key else None,
            )
            operation_now_ms = _now_ms()
            expires_at_ms = operation_now_ms + 10 * 60 * 1000
            result = {
                "hub_activation_token": mint_hub_activation_token(
                    settings.hub_activation_private_key,
                    route_id=body.hub_route_id,
                    expires_at_ms=expires_at_ms,
                    token_id=b64url_encode(secrets.token_bytes(16)),
                    key_id=settings.hub_activation_key_id,
                ),
                "hub_activation_token_expires_at_ms": expires_at_ms,
            }
            encrypted_response = vault.encrypt(
                json.dumps(result, sort_keys=True, separators=(",", ":")),
                endpoint_id=body.hub_route_id,
                bundle_id=body.bundle_id,
                environment=body.environment,
            )
            try:
                receipt, created = await database_call(
                    store.consume_hub_activation,
                    challenge_hash=challenge_hash,
                    request_hash=request_hash,
                    key_id_hash=key_id_hash,
                    public_key_der=identity.public_key_der,
                    counter=identity.counter,
                    route_id=body.hub_route_id,
                    bundle_id=body.bundle_id,
                    environment=body.environment,
                    encrypted_response=encrypted_response,
                    response_expires_at_ms=expires_at_ms,
                    reservation_token=reservation_token,
                    now_ms=operation_now_ms,
                )
            except Forbidden as exc:
                raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
            except Conflict as exc:
                raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
            committed = True
        finally:
            if not committed:
                await release_attestation(
                    challenge_hash=challenge_hash, owner_token=reservation_token
                )
        if not created:
            response.status_code = status.HTTP_200_OK
        return json.loads(
            vault.decrypt(
                receipt.encrypted_response,
                endpoint_id=receipt.route_id,
                bundle_id=receipt.bundle_id,
                environment=receipt.environment,
            )
        )

    @app.post("/v2/endpoints/register", status_code=status.HTTP_201_CREATED)
    async def register(
        body: EndpointRegistration, request: Request, response: Response
    ) -> dict[str, Any]:
        _no_store(response)
        if body.bundle_id not in settings.allowed_bundle_ids:
            raise _error("bundle_not_allowed", status.HTTP_403_FORBIDDEN)
        transcript = registration_transcript(
            challenge=body.challenge,
            apns_token=body.apns_token,
            bundle_id=body.bundle_id,
            environment=body.environment,
            preview_kem_pub=body.preview_kem_pub,
            installation_nonce=body.installation_nonce,
            operation="endpoint-register",
            hub_route_id=body.hub_route_id,
        )
        digest = hashlib.sha256(transcript).digest()
        app_key_hash = key_hash(body.app_attest_key_id)
        challenge_hash = secret_hash(body.challenge, settings.capability_pepper)
        request_hash = _canonical_model_hash(body)
        now_ms = _now_ms()
        try:
            prior = await database_call(
                store.get_registration_receipt,
                challenge_hash=challenge_hash,
                request_hash=request_hash,
                key_id_hash=app_key_hash,
                now_ms=now_ms,
            )
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        if prior is not None:
            response.status_code = status.HTTP_200_OK
            return json.loads(
                vault.decrypt(
                    prior.encrypted_response,
                    endpoint_id=prior.endpoint_id,
                    bundle_id=prior.bundle_id,
                    environment=prior.environment,
                )
            )
        reservation_token = await reserve_attestation(
            challenge_hash=challenge_hash, request_hash=request_hash
        )
        if reservation_token is None:
            try:
                prior = await database_call(
                    store.get_registration_receipt,
                    challenge_hash=challenge_hash,
                    request_hash=request_hash,
                    key_id_hash=app_key_hash,
                    now_ms=_now_ms(),
                )
            except Conflict as exc:
                raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
            if prior is None:
                raise _error(
                    "registration_receipt_unavailable", status.HTTP_409_CONFLICT
                )
            response.status_code = status.HTTP_200_OK
            return json.loads(
                vault.decrypt(
                    prior.encrypted_response,
                    endpoint_id=prior.endpoint_id,
                    bundle_id=prior.bundle_id,
                    environment=prior.environment,
                )
            )

        committed = False
        try:
            existing_key = await database_call(store.get_attest_key, app_key_hash)
            if (
                existing_key is None
                and body.attestation is None
                and not development_attestation_authorized(request)
            ):
                raise _error("app_attest_initial_required", status.HTTP_409_CONFLICT)
            identity = await run_attestation_verifier(
                request=request,
                key_id=body.app_attest_key_id,
                assertion=body.assertion,
                attestation=body.attestation,
                transcript=transcript,
                digest=digest,
                bundle_id=body.bundle_id,
                environment=body.environment,
                existing_public_key_der=(
                    existing_key.public_key_der if existing_key else None
                ),
                existing_counter=existing_key.counter if existing_key else None,
            )
            installation_hash = opaque_hash(
                body.installation_nonce, settings.capability_pepper
            )
            recovery = await database_call(
                store.get_endpoint_by_installation, installation_hash
            )
            preview_key = b64url_decode(
                body.preview_kem_pub, field="preview_kem_pub", exact=32
            )
            if recovery is not None:
                if recovery.attest_key_hash != app_key_hash:
                    raise _error("installation_key_mismatch", status.HTTP_409_CONFLICT)
                if (
                    recovery.bundle_id != body.bundle_id
                    or recovery.environment != body.environment
                    or recovery.preview_kem_pub != preview_key
                    or recovery.status == "revoked"
                ):
                    raise _error(
                        "installation_recovery_binding_mismatch",
                        status.HTTP_403_FORBIDDEN,
                    )
                endpoint_id = recovery.endpoint_id
            else:
                endpoint_id = "ep_" + b64url_encode(secrets.token_bytes(24))
            operation_now_ms = _now_ms()
            bind_token = b64url_encode(secrets.token_bytes(32))
            bind_expires_at_ms = (
                operation_now_ms + settings.bind_token_ttl_seconds * 1000
            )
            result: dict[str, Any] = {
                "endpoint_id": endpoint_id,
                "bind_token": bind_token,
                "bind_token_expires_at_ms": bind_expires_at_ms,
            }
            if (
                body.hub_route_id is not None
                and settings.hub_activation_private_key is not None
            ):
                activation_expires = operation_now_ms + 10 * 60 * 1000
                result["hub_activation_token"] = mint_hub_activation_token(
                    settings.hub_activation_private_key,
                    route_id=body.hub_route_id,
                    expires_at_ms=activation_expires,
                    token_id=b64url_encode(secrets.token_bytes(16)),
                    key_id=settings.hub_activation_key_id,
                )
                result["hub_activation_token_expires_at_ms"] = activation_expires
            encrypted = vault.encrypt(
                body.apns_token,
                endpoint_id=endpoint_id,
                bundle_id=body.bundle_id,
                environment=body.environment,
            )
            encrypted_response = vault.encrypt(
                json.dumps(result, sort_keys=True, separators=(",", ":")),
                endpoint_id=endpoint_id,
                bundle_id=body.bundle_id,
                environment=body.environment,
            )
            try:
                receipt, created = await database_call(
                    store.register_endpoint,
                    challenge_hash=challenge_hash,
                    request_hash=request_hash,
                    key_id_hash=app_key_hash,
                    public_key_der=identity.public_key_der,
                    counter=identity.counter,
                    endpoint_id=endpoint_id,
                    encrypted_token=encrypted,
                    environment=body.environment,
                    bundle_id=body.bundle_id,
                    preview_kem_pub=preview_key,
                    installation_nonce_hash=installation_hash,
                    bind_token_hash=secret_hash(bind_token, settings.capability_pepper),
                    bind_expires_at_ms=bind_expires_at_ms,
                    encrypted_response=encrypted_response,
                    response_expires_at_ms=bind_expires_at_ms,
                    reservation_token=reservation_token,
                    now_ms=operation_now_ms,
                )
            except Forbidden as exc:
                raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
            except Conflict as exc:
                raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
            committed = True
        finally:
            if not committed:
                await release_attestation(
                    challenge_hash=challenge_hash, owner_token=reservation_token
                )
        if not created:
            response.status_code = status.HTTP_200_OK
        return json.loads(
            vault.decrypt(
                receipt.encrypted_response,
                endpoint_id=receipt.endpoint_id,
                bundle_id=receipt.bundle_id,
                environment=receipt.environment,
            )
        )

    @app.post("/v2/endpoints/token-refresh")
    async def refresh(
        body: EndpointTokenRefresh, request: Request, response: Response
    ) -> dict[str, Any]:
        _no_store(response)
        endpoint = await database_call(store.get_endpoint, body.endpoint_id)
        if endpoint is None:
            raise _error("endpoint_not_found", status.HTTP_404_NOT_FOUND)
        preview_key = b64url_decode(
            body.preview_kem_pub, field="preview_kem_pub", exact=32
        )
        installation_hash = opaque_hash(
            body.installation_nonce, settings.capability_pepper
        )
        if (
            body.bundle_id != endpoint.bundle_id
            or body.environment != endpoint.environment
            or preview_key != endpoint.preview_kem_pub
            or installation_hash != endpoint.installation_nonce_hash
        ):
            raise _error("endpoint_binding_mismatch", status.HTTP_403_FORBIDDEN)
        transcript = registration_transcript(
            challenge=body.challenge,
            apns_token=body.apns_token,
            bundle_id=body.bundle_id,
            environment=body.environment,
            preview_kem_pub=body.preview_kem_pub,
            installation_nonce=body.installation_nonce,
            operation="token-refresh",
        )
        digest = hashlib.sha256(transcript).digest()
        app_key_hash = key_hash(body.app_attest_key_id)
        challenge_hash = secret_hash(body.challenge, settings.capability_pepper)
        request_hash = _canonical_model_hash(body)
        reservation_token = await reserve_attestation(
            challenge_hash=challenge_hash, request_hash=request_hash
        )
        if reservation_token is None:
            return {"endpoint_id": body.endpoint_id, "refreshed": True}

        committed = False
        try:
            existing_key = await database_call(store.get_attest_key, app_key_hash)
            if existing_key is None:
                raise _error("app_attest_initial_required", status.HTTP_409_CONFLICT)
            if app_key_hash != endpoint.attest_key_hash:
                raise _error("installation_key_mismatch", status.HTTP_409_CONFLICT)
            identity = await run_attestation_verifier(
                request=request,
                key_id=body.app_attest_key_id,
                assertion=body.assertion,
                attestation=None,
                transcript=transcript,
                digest=digest,
                bundle_id=body.bundle_id,
                environment=body.environment,
                existing_public_key_der=existing_key.public_key_der,
                existing_counter=existing_key.counter,
            )
            encrypted = vault.encrypt(
                body.apns_token,
                endpoint_id=body.endpoint_id,
                bundle_id=body.bundle_id,
                environment=body.environment,
            )
            try:
                await database_call(
                    store.refresh_endpoint,
                    endpoint_id=body.endpoint_id,
                    challenge_hash=challenge_hash,
                    request_hash=request_hash,
                    key_id_hash=app_key_hash,
                    public_key_der=identity.public_key_der,
                    counter=identity.counter,
                    encrypted_token=encrypted,
                    reservation_token=reservation_token,
                    now_ms=_now_ms(),
                )
            except NotFound as exc:
                raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
            except Forbidden as exc:
                raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
            except Conflict as exc:
                raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
            committed = True
        finally:
            if not committed:
                await release_attestation(
                    challenge_hash=challenge_hash, owner_token=reservation_token
                )
        return {"endpoint_id": body.endpoint_id, "refreshed": True}

    @app.post("/v2/bindings/exchange", status_code=status.HTTP_201_CREATED)
    async def exchange(body: BindingExchange, response: Response) -> dict[str, Any]:
        _no_store(response)
        allowed = frozenset(body.requested_classes or _ALL_CLASSES)
        if not allowed.issubset(_ALL_CLASSES):
            raise _error("binding_class_not_allowed", status.HTTP_403_FORBIDDEN)
        binding_id = "pb_" + b64url_encode(secrets.token_bytes(24))
        capability = b64url_encode(secrets.token_bytes(32))
        now_ms = _now_ms()
        encrypted_capability = vault.encrypt(
            capability,
            endpoint_id=binding_id,
            bundle_id="binding",
            environment="capability",
        )
        try:
            receipt, created = await database_call(
                store.exchange_binding,
                bind_token_hash=secret_hash(
                    body.bind_token, settings.capability_pepper
                ),
                exchange_id_hash=opaque_hash(
                    body.exchange_id, settings.capability_pepper
                ),
                request_hash=_canonical_model_hash(body),
                binding_id=binding_id,
                capability_hash=secret_hash(capability, settings.capability_pepper),
                encrypted_capability=encrypted_capability,
                allowed_classes=allowed,
                receipt_expires_at_ms=(
                    now_ms + settings.response_receipt_ttl_seconds * 1000
                ),
                now_ms=now_ms,
            )
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        if not created:
            response.status_code = status.HTTP_200_OK
        capability = vault.decrypt(
            receipt.encrypted_capability,
            endpoint_id=receipt.binding_id,
            bundle_id="binding",
            environment="capability",
        )
        return {
            "binding_id": receipt.binding_id,
            "send_capability": capability,
            "allowed_classes": sorted(receipt.allowed_classes),
        }

    @app.post("/v2/bindings/exchange/revoke")
    async def revoke_exchange(
        body: BindingExchangeRevoke, response: Response
    ) -> dict[str, bool]:
        """Revoke or pre-empt one exact exchange without returning authority."""

        _no_store(response)
        try:
            await database_call(
                store.revoke_binding_exchange,
                bind_token_hash=secret_hash(
                    body.bind_token, settings.capability_pepper
                ),
                exchange_id_hash=opaque_hash(
                    body.exchange_id, settings.capability_pepper
                ),
                now_ms=_now_ms(),
            )
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        # Identical first/retry bodies avoid exposing whether the exchange
        # created a binding or had already been revoked.
        return {"revoked": True}

    @app.post("/v2/send")
    async def send(
        body: SendRequest, request: Request, response: Response
    ) -> dict[str, Any]:
        _no_store(response)
        capability = _bearer(request)
        binding = await database_call(
            store.authenticate_binding,
            secret_hash(capability, settings.capability_pepper),
        )
        if binding is None:
            raise _error("send_capability_invalid", status.HTTP_401_UNAUTHORIZED)
        if body.notification_class not in binding.allowed_classes:
            raise _error("notification_class_forbidden", status.HTTP_403_FORBIDDEN)
        now_ms = _now_ms()
        if body.expires_at_ms <= now_ms:
            raise _error("notification_expired", status.HTTP_422_UNPROCESSABLE_CONTENT)
        if body.expires_at_ms > now_ms + 86_400_000:
            raise _error(
                "notification_ttl_too_long", status.HTTP_422_UNPROCESSABLE_CONTENT
            )
        try:
            _payload, serialized = build_payload(body)
        except PayloadTooLarge as exc:
            raise _error(
                "apns_payload_too_large", status.HTTP_413_CONTENT_TOO_LARGE
            ) from exc
        if sender_holder["sender"] is None:
            raise _error("apns_unavailable", status.HTTP_503_SERVICE_UNAVAILABLE)
        canonical = json.dumps(
            body.model_dump(by_alias=True), sort_keys=True, separators=(",", ":")
        ).encode()
        notification_hash = opaque_hash(
            body.notification_id, settings.capability_pepper
        )
        apns_id, derived_collapse_id = delivery_identifiers(
            binding_id=binding.binding_id,
            notification_id=body.notification_id,
            pepper=settings.capability_pepper,
        )
        delivery_collapse_id = body.collapse_id or derived_collapse_id
        try:
            reservation = await database_call(
                store.reserve_send,
                binding_id=binding.binding_id,
                notification_id_hash=notification_hash,
                request_hash=hashlib.sha256(canonical).digest(),
                apns_id=apns_id,
                collapse_id=delivery_collapse_id,
                now_ms=now_ms,
                expires_at_ms=body.expires_at_ms,
            )
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        except Conflict as exc:
            raise _error(str(exc), status.HTTP_409_CONFLICT) from exc
        except RateLimited as exc:
            headers = None
            if exc.retry_after_ms is not None:
                headers = {
                    "Retry-After": str(max(1, math.ceil(exc.retry_after_ms / 1000)))
                }
            raise _error(
                str(exc), status.HTTP_429_TOO_MANY_REQUESTS, headers=headers
            ) from exc
        if reservation.in_flight:
            raise _error("push_delivery_in_progress", status.HTTP_425_TOO_EARLY)
        if reservation.deduplicated:
            accepted = reservation.previous_status == "sent"
            if not accepted:
                response.status_code = status.HTTP_502_BAD_GATEWAY
            return {
                "accepted": accepted,
                "deduplicated": True,
                "status": reservation.previous_status,
                "provider_status": reservation.provider_status,
                "endpoint_pruned": reservation.provider_status == 410,
            }
        endpoint = await database_call(store.get_endpoint, binding.endpoint_id)
        if endpoint is None or endpoint.status != "active":
            raise _error("endpoint_not_active", status.HTTP_410_GONE)
        try:
            token = vault.decrypt(
                endpoint.token,
                endpoint_id=endpoint.endpoint_id,
                bundle_id=endpoint.bundle_id,
                environment=endpoint.environment,
            )
            result: APNsResult = await sender_holder["sender"].send(
                endpoint=APNsEndpoint(
                    token=token,
                    environment=endpoint.environment,
                    bundle_id=endpoint.bundle_id,
                ),
                payload=serialized,
                collapse_id=reservation.collapse_id,
                apns_id=reservation.apns_id,
                expires_at_ms=body.expires_at_ms,
            )
        except Exception as exc:
            # Exceptions from HTTP clients can embed the token-bearing APNs URL.
            # Never attach traceback/exception text to production logs here.
            logger.error("opaque push delivery failed before provider response")
            await database_call(
                store.complete_send,
                binding_id=binding.binding_id,
                notification_id_hash=notification_hash,
                delivery_status="ambiguous",
                provider_status=0,
                prune_endpoint=False,
                now_ms=_now_ms(),
                attempt_token=reservation.attempt_token,
            )
            raise _error("apns_delivery_failed", status.HTTP_502_BAD_GATEWAY) from exc
        await database_call(
            store.complete_send,
            binding_id=binding.binding_id,
            notification_id_hash=notification_hash,
            delivery_status=(
                "sent"
                if result.ok
                else (
                    "retryable"
                    if result.retryable
                    or result.status == 0
                    or result.status == 429
                    or result.status >= 500
                    else "permanent_rejected"
                )
            ),
            provider_status=result.status,
            prune_endpoint=result.should_prune,
            now_ms=_now_ms(),
            attempt_token=reservation.attempt_token,
            provider_retry_after_ms=result.retry_after_ms,
        )
        logger.info(
            "opaque push attempted binding_hash=%s class=%s bytes=%d provider_status=%d pruned=%s",
            hashlib.sha256(binding.binding_id.encode()).hexdigest()[:12],
            body.notification_class,
            len(serialized),
            result.status,
            result.should_prune,
        )
        if not result.ok:
            response.status_code = status.HTTP_502_BAD_GATEWAY
            if result.retry_after_ms is not None:
                response.headers["Retry-After"] = str(
                    max(1, math.ceil(result.retry_after_ms / 1000))
                )
        return {
            "accepted": result.ok,
            "deduplicated": False,
            "provider_status": result.status,
            "endpoint_pruned": result.should_prune,
        }

    @app.delete("/v2/bindings/{binding_id}")
    async def revoke(binding_id: str, request: Request) -> dict[str, Any]:
        capability = _bearer(request)
        try:
            changed = await database_call(
                store.revoke_binding,
                binding_id=binding_id,
                capability_hash=secret_hash(capability, settings.capability_pepper),
                now_ms=_now_ms(),
            )
        except NotFound as exc:
            raise _error(str(exc), status.HTTP_404_NOT_FOUND) from exc
        except Forbidden as exc:
            raise _error(str(exc), status.HTTP_403_FORBIDDEN) from exc
        return {
            "binding_id": binding_id,
            "revoked": True,
            "already_revoked": not changed,
        }

    return app
