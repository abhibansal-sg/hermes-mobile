"""Content-blind Relay Hub HTTP/WebSocket client.

Only :class:`~hermes_relay.v2.protocol.OuterEnvelope` crosses this boundary.
The client deliberately has no API accepting an RPC method, session ID,
prompt, notification title/body or arbitrary inner payload.
"""

from __future__ import annotations

import asyncio
import hashlib
import inspect
import json
import secrets
import time
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.parse import urlsplit, urlunsplit

from cryptography.hazmat.primitives.asymmetric import ed25519

from .errors import (
    Conflict,
    Expired,
    MailboxFull,
    NotFound,
    RateLimited,
    Revoked,
    Unauthenticated,
)
from .protocol import (
    OuterEnvelope,
    b64url_decode,
    b64url_encode,
    canonical_json,
    decode_strict_json,
)
from .service_url import canonical_service_origin


class HubUnavailable(ConnectionError):
    """The untrusted transport is temporarily unavailable."""


class RequestAuthenticator(Protocol):
    def __call__(self, method: str, path: str, body: bytes) -> Mapping[str, str]: ...


@dataclass(frozen=True, slots=True)
class HubConfig:
    base_url: str
    route_id: str
    request_timeout_s: float = 15.0
    reconnect_initial_s: float = 0.5
    reconnect_max_s: float = 30.0
    allow_insecure_local: bool = False

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "base_url",
            canonical_service_origin(
                self.base_url,
                label="Hub base_url",
                allow_insecure_local=self.allow_insecure_local,
            ),
        )
        if not self.route_id:
            raise ValueError("Hub route_id is required")


class Ed25519RequestAuthenticator:
    """Route-scoped signed request headers for non-envelope mutations.

    The body is hashed and never copied into a header.  A hosted deployment can
    inject a different authenticator without changing the HubClient.
    """

    def __init__(
        self,
        route_id: str,
        private_key: bytes,
        *,
        clock_ms: Callable[[], int] = lambda: time.time_ns() // 1_000_000,
    ) -> None:
        self.route_id = route_id
        self._key = ed25519.Ed25519PrivateKey.from_private_bytes(private_key)
        self._clock = clock_ms

    def __call__(self, method: str, path: str, body: bytes) -> Mapping[str, str]:
        timestamp = str(self._clock())
        nonce_bytes = secrets.token_bytes(16)
        nonce = b64url_encode(nonce_bytes)
        pieces = [
            method.upper().encode("ascii"),
            path.encode("utf-8"),
            self.route_id.encode("utf-8"),
            timestamp.encode("ascii"),
            nonce_bytes,
            hashlib.sha256(body).digest(),
        ]
        transcript = bytearray(b"HRH2REQ")
        for piece in pieces:
            transcript.extend(len(piece).to_bytes(4, "big"))
            transcript.extend(piece)
        signature = self._key.sign(bytes(transcript))
        return {
            "X-Hermes-Route": self.route_id,
            "X-Hermes-Timestamp": timestamp,
            "X-Hermes-Nonce": nonce,
            "X-Hermes-Signature": b64url_encode(signature),
        }


class HubClient:
    def __init__(
        self,
        config: HubConfig,
        *,
        authenticator: RequestAuthenticator | None = None,
        http_client: Any = None,
        websocket_connector: Callable[..., Awaitable[Any]] | None = None,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ) -> None:
        self.config = config
        self._authenticator = authenticator
        self._http = http_client
        self._owns_http = http_client is None
        self._ws_connector = websocket_connector
        self._sleep = sleep
        self._closing = False

    async def send_envelope(self, envelope: OuterEnvelope) -> dict[str, Any]:
        body = envelope.to_json()
        # The signed outer envelope itself authorizes this endpoint; route
        # request nonces are reserved for mutations without an outer envelope.
        response = await self._request("POST", "/v2/messages", body, authenticate=False)
        result = self._response_json(response)
        if set(result) != {"accepted", "deduplicated", "stored", "mid"}:
            raise HubUnavailable("malformed Hub acceptance")
        if (
            result["accepted"] is not True
            or not isinstance(result["deduplicated"], bool)
            or not isinstance(result["stored"], bool)
            or not isinstance(result["mid"], str)
            or result["mid"] != envelope.mid
        ):
            raise HubUnavailable("invalid Hub acceptance")
        return result

    async def enroll_provisional_agent(
        self, *, enrollment_id: str, auth_public_key: bytes
    ) -> dict[str, Any]:
        """Create a pairing-quota Agent route before long-term activation."""

        if not isinstance(enrollment_id, str) or not enrollment_id.startswith("enr_"):
            raise ValueError("enrollment_id must be a persisted enr_ identifier")
        if not isinstance(auth_public_key, bytes) or len(auth_public_key) != 32:
            raise ValueError("auth_public_key must be 32 bytes")
        body = canonical_json({
            "enrollment_id": enrollment_id,
            "route_type": "agent",
            "auth_public_key": b64url_encode(auth_public_key),
        })
        response = await self._request(
            "POST", "/v2/enroll/provisional", body, authenticate=False
        )
        result = self._response_json(response)
        if (
            set(result) != {"enrollment_id", "route_id", "status", "expires_at_ms"}
            or result.get("enrollment_id") != enrollment_id
            or not isinstance(result.get("route_id"), str)
            or result.get("status") != "provisional"
            or not isinstance(result.get("expires_at_ms"), int)
        ):
            raise HubUnavailable("malformed provisional enrollment response")
        return result

    async def activate_agent_route(
        self,
        *,
        activation_token: str | None = None,
        operator_enrollment_token: str | None = None,
        development_token: str | None = None,
    ) -> dict[str, Any]:
        if (
            not activation_token
            and not operator_enrollment_token
            and not development_token
        ):
            raise Unauthenticated("Hub activation authority is required")
        body = canonical_json({
            "route_id": self.config.route_id,
            "activation_token": activation_token,
        })
        headers: dict[str, str] = {}
        if operator_enrollment_token:
            headers["X-Hermes-Enrollment-Token"] = operator_enrollment_token
        if development_token:
            headers["X-Hermes-Development-Token"] = development_token
        response = await self._request(
            "POST",
            "/v2/enroll/activate",
            body,
            authenticate=False,
            extra_headers=headers,
        )
        result = self._response_json(response)
        if (
            set(result) != {"route_id", "status", "already_active"}
            or result.get("route_id") != self.config.route_id
            or result.get("status") != "active"
            or not isinstance(result.get("already_active"), bool)
        ):
            raise HubUnavailable("malformed route activation response")
        return result

    async def prove_route(self) -> dict[str, str]:
        """Prove signed ownership for either a provisional or active Agent."""

        response = await self._request("GET", "/v2/route-proof", b"")
        result = self._response_json(response)
        if (
            set(result) != {"route_id", "status"}
            or result.get("route_id") != self.config.route_id
            or result.get("status") not in {"provisional", "active"}
        ):
            raise HubUnavailable("malformed route ownership proof")
        return {"route_id": result["route_id"], "status": result["status"]}

    async def acknowledge(self, message_ids: list[str]) -> dict[str, Any]:
        if not message_ids or any(
            not isinstance(mid, str) or not mid for mid in message_ids
        ):
            raise ValueError("message_ids must be non-empty strings")
        body = canonical_json({"message_ids": message_ids})
        response = await self._request("POST", "/v2/acks", body)
        result = self._response_json(response)
        if (
            set(result) != {"acknowledged"}
            or not isinstance(result.get("acknowledged"), int)
            or isinstance(result.get("acknowledged"), bool)
            or not 0 <= result["acknowledged"] <= len(message_ids)
        ):
            raise HubUnavailable("malformed Hub acknowledgement")
        return result

    async def create_grant(self, grant: Mapping[str, Any]) -> dict[str, Any]:
        # Grant contents are routes/permissions only; this method cannot carry
        # an inner Hermes payload.
        body = canonical_json(dict(grant))
        response = await self._request("POST", "/v2/grants", body)
        result = self._response_json(response)
        if (
            set(result) != {"grant_id", "created", "status"}
            or result.get("grant_id") != grant.get("grant_id")
            or not isinstance(result.get("created"), bool)
            or result.get("status") not in {"pending", "active"}
        ):
            raise HubUnavailable("malformed Hub grant response")
        return result

    async def create_pending_device_route(
        self, *, auth_public_key: bytes, offer_id: str
    ) -> dict[str, Any]:
        if not isinstance(auth_public_key, bytes) or len(auth_public_key) != 32:
            raise ValueError("auth_public_key must be 32 bytes")
        body = canonical_json({
            "route_type": "device",
            "auth_public_key": b64url_encode(auth_public_key),
            "offer_id": offer_id,
        })
        response = await self._request("POST", "/v2/routes", body)
        result = self._response_json(response)
        if (
            set(result) != {"route_id", "status", "owner_route", "offer_id"}
            or not isinstance(result.get("route_id"), str)
            or result.get("status") != "pending"
            or result.get("owner_route") != self.config.route_id
            or result.get("offer_id") != offer_id
        ):
            raise HubUnavailable("malformed pending-route response")
        return result

    async def register_pair_offer(
        self,
        *,
        offer_id: str,
        offer_route: str,
        transport_token: str,
        owner_route: str,
        expires_at_ms: int,
    ) -> dict[str, Any]:
        raw_token = b64url_decode(
            transport_token, field="transport_token", exact_bytes=32
        )
        body = canonical_json({
            "offer_id": offer_id,
            "offer_route": offer_route,
            "transport_token_hash": b64url_encode(hashlib.sha256(raw_token).digest()),
            "owner_route": owner_route,
            "expires_at_ms": expires_at_ms,
        })
        response = await self._request("POST", "/v2/offers", body)
        result = self._response_json(response)
        if result != {
            "offer_id": offer_id,
            "offer_route": offer_route,
            "expires_at_ms": expires_at_ms,
        }:
            raise HubUnavailable("malformed pairing-offer registration")
        return result

    async def get_pair_offer(self, offer_id: str) -> dict[str, Any]:
        response = await self._request("GET", f"/v2/offers/{offer_id}", b"")
        result = self._response_json(response)
        if result == {"status": "waiting"}:
            return result
        required = {"status", "v", "offer_id", "enc", "ct", "message_hash"}
        if (
            set(result) != required
            or result.get("status") != "ready"
            or result.get("v") != 2
        ):
            raise HubUnavailable("malformed pairing mailbox response")
        if result.get("offer_id") != offer_id:
            raise HubUnavailable("pairing mailbox offer mismatch")
        b64url_decode(result["enc"], field="enc", exact_bytes=32)
        b64url_decode(result["ct"], field="ct", min_bytes=16, max_bytes=32768)
        b64url_decode(result["message_hash"], field="message_hash", exact_bytes=32)
        return result

    async def accept_pair_offer(
        self,
        *,
        offer_id: str,
        message_hash: str,
        device_route: str,
        enc: bytes,
        ciphertext: bytes,
    ) -> dict[str, Any]:
        b64url_decode(message_hash, field="message_hash", exact_bytes=32)
        if not isinstance(enc, bytes) or len(enc) != 32:
            raise ValueError("enc must be 32 bytes")
        if not isinstance(ciphertext, bytes) or not 16 <= len(ciphertext) <= 32768:
            raise ValueError("ciphertext must be 16..32768 bytes")
        body = canonical_json({
            "message_hash": message_hash,
            "device_route": device_route,
            "enc": b64url_encode(enc),
            "ct": b64url_encode(ciphertext),
        })
        response = await self._request("POST", f"/v2/offers/{offer_id}/accept", body)
        result = self._response_json(response)
        if (
            set(result) != {"status", "offer_id", "device_route", "response_hash"}
            or result.get("status") != "accepted"
            or result.get("offer_id") != offer_id
            or result.get("device_route") != device_route
        ):
            raise HubUnavailable("malformed PairAccept response")
        response_hash = b64url_encode(hashlib.sha256(enc + ciphertext).digest())
        if result.get("response_hash") != response_hash:
            raise HubUnavailable("PairAccept response hash mismatch")
        return result

    async def get_pair_accept(
        self, *, offer_route: str, transport_token: str, offer_id: str
    ) -> dict[str, Any]:
        """Phone/reference helper for fetching the one encrypted PairAccept."""

        b64url_decode(transport_token, field="transport_token", exact_bytes=32)
        response = await self._request(
            "GET",
            f"/v2/offers/{offer_route}/accept",
            b"",
            authenticate=False,
            extra_headers={"Authorization": f"Bearer {transport_token}"},
        )
        result = self._response_json(response)
        if result == {"status": "waiting", "offer_id": offer_id}:
            return result
        required = {"v", "offer_id", "device_route", "enc", "ct", "response_hash"}
        if (
            set(result) != required
            or result.get("v") != 2
            or result.get("offer_id") != offer_id
        ):
            raise HubUnavailable("malformed PairAccept mailbox response")
        enc = b64url_decode(result["enc"], field="enc", exact_bytes=32)
        ct = b64url_decode(result["ct"], field="ct", min_bytes=16, max_bytes=32768)
        expected = b64url_encode(hashlib.sha256(enc + ct).digest())
        if result.get("response_hash") != expected:
            raise HubUnavailable("PairAccept mailbox hash mismatch")
        return result

    async def confirm_pair_offer(
        self,
        *,
        offer_id: str,
        message_hash: str,
        response_hash: str,
        device_route: str,
    ) -> dict[str, Any]:
        b64url_decode(message_hash, field="message_hash", exact_bytes=32)
        b64url_decode(response_hash, field="response_hash", exact_bytes=32)
        body = canonical_json({
            "message_hash": message_hash,
            "response_hash": response_hash,
            "device_route": device_route,
        })
        response = await self._request("POST", f"/v2/offers/{offer_id}/confirm", body)
        result = self._response_json(response)
        if (
            set(result) != {"device_route", "status", "grant_ids"}
            or result.get("device_route") != device_route
            or result.get("status") != "active"
            or not isinstance(result.get("grant_ids"), list)
            or len(result["grant_ids"]) != 2
            or any(
                not isinstance(value, str) or not value for value in result["grant_ids"]
            )
        ):
            raise HubUnavailable("malformed PairConfirm response")
        return result

    async def cancel_pair_offer(self, offer_id: str) -> None:
        await self._request("DELETE", f"/v2/offers/{offer_id}/cancel", b"")

    async def submit_pair_init(
        self,
        *,
        offer_route: str,
        transport_token: str,
        offer_id: str,
        enc: bytes,
        ciphertext: bytes,
    ) -> dict[str, Any]:
        # Phone-side/reference helper used by E2E tests; established Agent
        # traffic never uses this bearer path.
        b64url_decode(transport_token, field="transport_token", exact_bytes=32)
        body = canonical_json({
            "v": 2,
            "offer_id": offer_id,
            "enc": b64url_encode(enc),
            "ct": b64url_encode(ciphertext),
        })
        response = await self._request(
            "POST",
            f"/v2/offers/{offer_route}/messages",
            body,
            authenticate=False,
            extra_headers={"Authorization": f"Bearer {transport_token}"},
        )
        return self._response_json(response)

    async def delete_grant(self, grant_id: str) -> None:
        await self._request("DELETE", f"/v2/grants/{grant_id}", b"")

    async def delete_route(self, route_id: str) -> dict[str, Any]:
        response = await self._request("DELETE", f"/v2/routes/{route_id}", b"")
        result = self._response_json(response)
        if (
            set(result) != {"route_id", "status", "grant_ids", "already_revoked"}
            or result.get("route_id") != route_id
            or result.get("status") != "revoked"
            or not isinstance(result.get("grant_ids"), list)
            or result["grant_ids"] != sorted(result["grant_ids"])
            or any(
                not isinstance(value, str) or not value for value in result["grant_ids"]
            )
            or not isinstance(result.get("already_revoked"), bool)
        ):
            raise HubUnavailable("malformed route revocation response")
        return result

    async def receive(self) -> AsyncIterator[OuterEnvelope]:
        """Reconnect forever and yield only strict outer envelopes."""

        self._closing = False
        delay = self.config.reconnect_initial_s
        while not self._closing:
            ws = None
            try:
                ws = await self._connect_ws()
                delay = self.config.reconnect_initial_s
                async for raw in ws:
                    envelope = self._decode_ws_message(raw)
                    if envelope is not None:
                        yield envelope
            except asyncio.CancelledError:
                raise
            except Exception:
                if self._closing:
                    break
                await self._sleep(delay)
                delay = min(delay * 2, self.config.reconnect_max_s)
            finally:
                if ws is not None:
                    close = getattr(ws, "close", None)
                    if close is not None:
                        result = close()
                    if inspect.isawaitable(result):
                        await result

    async def probe_receive_ready(self) -> None:
        """Prove the authenticated Hub socket can send and receive.

        The Hub's existing ping/pong control frame is content-free.  Mailbox
        replay frames may arrive before the pong, so they are ignored here and
        remain unacknowledged for the long-lived inbound processor.
        """

        ws = None
        try:
            ws = await self._connect_ws()
            await ws.send(json.dumps({"type": "ping"}, separators=(",", ":")))
            loop = asyncio.get_running_loop()
            deadline = loop.time() + self.config.request_timeout_s
            while True:
                remaining = deadline - loop.time()
                if remaining <= 0:
                    raise TimeoutError
                raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
                if isinstance(raw, str):
                    raw = raw.encode("utf-8")
                if not isinstance(raw, bytes):
                    continue
                try:
                    value = decode_strict_json(raw)
                except Exception:
                    continue
                if value == {"type": "pong"}:
                    return
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            raise HubUnavailable("authenticated Hub receive probe failed") from exc
        finally:
            if ws is not None:
                close = getattr(ws, "close", None)
                if close is not None:
                    result = close()
                    if inspect.isawaitable(result):
                        await result

    async def close(self) -> None:
        self._closing = True
        if self._owns_http and self._http is not None:
            await self._http.aclose()
            self._http = None

    async def _request(
        self,
        method: str,
        path: str,
        body: bytes,
        *,
        authenticate: bool = True,
        extra_headers: Mapping[str, str] | None = None,
    ) -> Any:
        client = self._http_client()
        headers = {"Content-Type": "application/json"}
        if authenticate and self._authenticator is None:
            raise Unauthenticated("Route authenticator is not configured")
        if authenticate and self._authenticator is not None:
            headers.update(self._authenticator(method, path, body))
        if extra_headers:
            headers.update(extra_headers)
        try:
            response = await client.request(
                method,
                self.config.base_url.rstrip("/") + path,
                content=body,
                headers=headers,
                timeout=self.config.request_timeout_s,
            )
        except Exception as exc:
            raise HubUnavailable() from exc
        self._raise_for_status(response)
        return response

    def _http_client(self) -> Any:
        if self._http is None:
            import httpx

            self._http = httpx.AsyncClient()
            self._owns_http = True
        return self._http

    def _auth_headers(
        self, method: str, path: str, body: bytes = b""
    ) -> dict[str, str]:
        return (
            dict(self._authenticator(method, path, body)) if self._authenticator else {}
        )

    async def _connect_ws(self) -> Any:
        if self._authenticator is None:
            raise Unauthenticated("Route authenticator is not configured")
        connector = self._ws_connector
        if connector is None:
            import websockets

            connector = websockets.connect
        url = self._websocket_url("/v2/socket")
        headers = self._auth_headers("GET", "/v2/socket")
        try:
            return await connector(url, additional_headers=headers)
        except TypeError:
            # websockets 12 used ``extra_headers``; retain compatibility with
            # the v1 relay's declared lower bound.
            return await connector(url, extra_headers=headers)

    def _websocket_url(self, path: str) -> str:
        parsed = urlsplit(self.config.base_url)
        scheme = "wss" if parsed.scheme == "https" else "ws"
        return urlunsplit((scheme, parsed.netloc, path, "", ""))

    @staticmethod
    def _decode_ws_message(raw: Any) -> OuterEnvelope | None:
        if isinstance(raw, str):
            raw = raw.encode("utf-8")
        if not isinstance(raw, bytes):
            return None
        decoded = decode_strict_json(raw)
        if not isinstance(decoded, dict):
            return None
        if set(decoded) == {"type", "envelope"}:
            if decoded.get("type") != "message" or not isinstance(
                decoded["envelope"], dict
            ):
                return None
            decoded = decoded["envelope"]
        return OuterEnvelope.from_dict(decoded)

    @staticmethod
    def _response_json(response: Any) -> dict[str, Any]:
        if not getattr(response, "content", b""):
            return {}
        try:
            value = response.json()
        except Exception as exc:
            raise HubUnavailable("malformed Hub JSON") from exc
        if not isinstance(value, dict):
            raise HubUnavailable("malformed Hub JSON object")
        return value

    @staticmethod
    def _raise_for_status(response: Any) -> None:
        status = int(getattr(response, "status_code", 0))
        if 200 <= status < 300:
            return
        code = ""
        try:
            payload = response.json()
            if isinstance(payload, dict):
                detail = payload.get("detail", payload)
                if isinstance(detail, dict):
                    error = detail.get("error", detail)
                    if isinstance(error, dict):
                        code = str(error.get("code", "")).upper()
        except Exception:
            pass
        if status in {401, 403} or code == "UNAUTHENTICATED":
            raise Unauthenticated()
        if code == "PROVISIONAL_ENROLLMENT_EXPIRED":
            raise Expired()
        if code == "PROVISIONAL_ENROLLMENT_REVOKED":
            raise Revoked()
        if status == 409 or code in {
            "CONFLICT",
            "MESSAGE_ID_CONFLICT",
            "ENROLLMENT_ID_CONFLICT",
        }:
            raise Conflict("Hub message ID conflict")
        if status == 410 or code == "REVOKED":
            raise Revoked()
        if status == 404 or code == "NOT_FOUND":
            raise NotFound()
        if code == "EXPIRED":
            raise Expired()
        if status == 429:
            # The Hub uses 429 both for reserved mailbox exhaustion and ordinary
            # rate limiting.  A stable error code, when present, disambiguates.
            if code == "MAILBOX_FULL":
                raise MailboxFull()
            raise RateLimited()
        if status >= 500 or status == 0:
            raise HubUnavailable()
        raise Conflict("Hub rejected the request")


__all__ = [
    "Ed25519RequestAuthenticator",
    "HubClient",
    "HubConfig",
    "HubUnavailable",
    "RequestAuthenticator",
]
