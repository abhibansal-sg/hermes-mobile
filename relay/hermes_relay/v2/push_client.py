"""Content-blind HRP/2 Push Gateway client.

The client accepts only the frozen encrypted notification descriptor.  It has
no API that accepts a title, body, session ID, request ID, or Hermes frame.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Mapping

from .protocol import (
    NotificationSendDescriptor,
    b64url_decode,
    b64url_encode,
    canonical_json,
)
from .service_url import canonical_service_origin


class PushGatewayUnavailable(ConnectionError):
    pass


class PushGatewayRejected(PushGatewayUnavailable):
    """Typed HTTP rejection so the durable sender can stop terminal retries."""

    def __init__(self, code: str, status_code: int) -> None:
        self.code = code
        self.status_code = status_code
        self.retryable = status_code in {408, 425, 429} or status_code >= 500
        super().__init__(f"Push Gateway rejected request: {code}")


@dataclass(frozen=True, slots=True)
class PushGatewayConfig:
    base_url: str
    timeout_s: float = 15.0
    allow_insecure_local: bool = False

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "base_url",
            canonical_service_origin(
                self.base_url,
                label="Push Gateway base_url",
                allow_insecure_local=self.allow_insecure_local,
            ),
        )


class PushGatewayClient:
    def __init__(self, config: PushGatewayConfig, *, http_client: Any = None) -> None:
        self.config = config
        self._http = http_client
        self._owns_http = http_client is None

    async def probe_ready(self) -> None:
        """Verify the configured gateway is production-ready without authority."""

        health = self._json(await self._request("GET", "/healthz", b""))
        if health != {"status": "ok", "apns_configured": True}:
            raise PushGatewayUnavailable(
                "Push Gateway is not configured for APNs"
            )
        response = await self._request("GET", "/readyz", b"")
        if self._json(response) != {"status": "ready"}:
            raise PushGatewayUnavailable("Push Gateway is not ready")

    async def exchange_binding(
        self,
        bind_token: str,
        *,
        exchange_id: str,
        requested_classes: list[str],
    ) -> dict[str, Any]:
        if not bind_token or not isinstance(bind_token, str):
            raise ValueError("bind_token is required")
        if not isinstance(exchange_id, str) or not 16 <= len(exchange_id) <= 128:
            raise ValueError("exchange_id must be a persisted opaque identifier")
        if not requested_classes or len(set(requested_classes)) != len(
            requested_classes
        ):
            raise ValueError("requested_classes must be unique and non-empty")
        body = canonical_json({
            "bind_token": bind_token,
            "exchange_id": exchange_id,
            "requested_classes": requested_classes,
        })
        response = await self._request("POST", "/v2/bindings/exchange", body)
        result = self._json(response)
        if (
            set(result) != {"binding_id", "send_capability", "allowed_classes"}
            or not isinstance(result.get("binding_id"), str)
            or not isinstance(result.get("send_capability"), str)
            or result.get("allowed_classes") != sorted(requested_classes)
        ):
            raise PushGatewayUnavailable("malformed binding exchange response")
        b64url_decode(
            result["send_capability"], field="send_capability", exact_bytes=32
        )
        return result

    async def send(
        self, descriptor: NotificationSendDescriptor, *, send_capability: bytes
    ) -> dict[str, Any]:
        if not isinstance(send_capability, bytes) or len(send_capability) != 32:
            raise ValueError("send_capability must be 32 bytes")
        response = await self._request(
            "POST",
            "/v2/send",
            canonical_json(descriptor.to_dict()),
            bearer=b64url_encode(send_capability),
            allow_delivery_failure=True,
        )
        result = self._json(response)
        if result.get("deduplicated") is True:
            if set(result) != {
                "accepted",
                "deduplicated",
                "status",
                "provider_status",
                "endpoint_pruned",
            }:
                raise PushGatewayUnavailable("malformed deduplicated push response")
            if (
                not isinstance(result.get("accepted"), bool)
                or result.get("status") not in {"sent", "permanent_rejected"}
                or result.get("accepted") != (result.get("status") == "sent")
                or (
                    result.get("provider_status") is not None
                    and not isinstance(result.get("provider_status"), int)
                )
                or not isinstance(result.get("endpoint_pruned"), bool)
            ):
                raise PushGatewayUnavailable("invalid deduplicated push response")
        else:
            if set(result) != {
                "accepted",
                "deduplicated",
                "provider_status",
                "endpoint_pruned",
            }:
                raise PushGatewayUnavailable("malformed push response")
            if (
                not isinstance(result.get("accepted"), bool)
                or result.get("deduplicated") is not False
                or not isinstance(result.get("provider_status"), int)
                or not isinstance(result.get("endpoint_pruned"), bool)
            ):
                raise PushGatewayUnavailable("invalid push response")
        return result

    async def revoke_binding(
        self, binding_id: str, *, send_capability: bytes
    ) -> dict[str, Any]:
        if not binding_id:
            raise ValueError("binding_id is required")
        if not isinstance(send_capability, bytes) or len(send_capability) != 32:
            raise ValueError("send_capability must be 32 bytes")
        response = await self._request(
            "DELETE",
            f"/v2/bindings/{binding_id}",
            b"",
            bearer=b64url_encode(send_capability),
        )
        result = self._json(response)
        if (
            set(result) != {"binding_id", "revoked", "already_revoked"}
            or result.get("binding_id") != binding_id
            or result.get("revoked") is not True
            or not isinstance(result.get("already_revoked"), bool)
        ):
            raise PushGatewayUnavailable("malformed binding revocation response")
        return result

    async def revoke_binding_exchange(
        self, bind_token: str, *, exchange_id: str
    ) -> dict[str, bool]:
        """Revoke an ambiguous exchange without recovering its capability."""

        if not bind_token or not isinstance(bind_token, str):
            raise ValueError("bind_token is required")
        if not isinstance(exchange_id, str) or not 16 <= len(exchange_id) <= 128:
            raise ValueError("exchange_id must be a persisted opaque identifier")
        response = await self._request(
            "POST",
            "/v2/bindings/exchange/revoke",
            canonical_json({
                "bind_token": bind_token,
                "exchange_id": exchange_id,
            }),
        )
        result = self._json(response)
        if result != {"revoked": True}:
            raise PushGatewayUnavailable(
                "malformed binding exchange revocation response"
            )
        return result

    async def _request(
        self,
        method: str,
        path: str,
        body: bytes,
        *,
        bearer: str | None = None,
        allow_delivery_failure: bool = False,
    ) -> Any:
        if self._http is None:
            import httpx

            self._http = httpx.AsyncClient(timeout=self.config.timeout_s)
        headers = {"Content-Type": "application/json"}
        if bearer is not None:
            headers["Authorization"] = f"Bearer {bearer}"
        try:
            response = await self._http.request(
                method,
                self.config.base_url.rstrip("/") + path,
                content=body,
                headers=headers,
            )
        except Exception as exc:
            raise PushGatewayUnavailable("Push Gateway request failed") from exc
        if 200 <= response.status_code < 300:
            return response
        if allow_delivery_failure and response.status_code == 502:
            # Provider failure is a typed delivery result, not malformed HTTP.
            try:
                payload = response.json()
            except Exception:
                payload = None
            if isinstance(payload, Mapping) and "accepted" in payload:
                return response
        code = self._error_code(response)
        raise PushGatewayRejected(code, response.status_code)

    @staticmethod
    def _json(response: Any) -> dict[str, Any]:
        try:
            value = response.json()
        except Exception as exc:
            raise PushGatewayUnavailable("Push Gateway returned non-JSON") from exc
        if not isinstance(value, dict):
            raise PushGatewayUnavailable("Push Gateway returned a non-object")
        return value

    @staticmethod
    def _error_code(response: Any) -> str:
        try:
            payload = response.json()
            detail = payload.get("detail", payload)
            error = detail.get("error", detail) if isinstance(detail, Mapping) else {}
            code = error.get("code") if isinstance(error, Mapping) else None
            return code if isinstance(code, str) else "push_gateway_error"
        except Exception:
            return "push_gateway_error"

    async def close(self) -> None:
        if self._owns_http and self._http is not None:
            close = getattr(self._http, "aclose", None)
            if close is not None:
                await close()
        self._http = None


__all__ = [
    "PushGatewayClient",
    "PushGatewayConfig",
    "PushGatewayRejected",
    "PushGatewayUnavailable",
]
