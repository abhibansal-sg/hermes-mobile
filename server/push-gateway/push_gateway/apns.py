from __future__ import annotations

import json
import logging
import math
import time
from dataclasses import dataclass
from email.utils import parsedate_to_datetime

import httpx
import jwt

from .models import SendRequest
from .settings import Settings

logger = logging.getLogger("push_gateway.apns")

_PRODUCTION_HOST = "https://api.push.apple.com"
_SANDBOX_HOST = "https://api.sandbox.push.apple.com"
_PERMANENT_TOKEN_REASONS = {"Unregistered"}
_PROVIDER_REASONS = {
    "InvalidProviderToken",
    "ExpiredProviderToken",
    "BadTopic",
    "MissingTopic",
    "TopicDisallowed",
}
MAX_APNS_RETRY_AFTER_MS = 3_600_000


class PayloadTooLarge(ValueError):
    def __init__(self, size: int) -> None:
        super().__init__("serialized APNs payload exceeds the 3,900-byte HRP/2 budget")
        self.size = size


@dataclass(frozen=True)
class APNsEndpoint:
    token: str
    environment: str
    bundle_id: str


@dataclass(frozen=True)
class APNsResult:
    ok: bool
    status: int
    should_prune: bool = False
    retryable: bool = False
    retry_after_ms: int | None = None


def build_payload(body: SendRequest) -> tuple[dict, bytes]:
    aps: dict = {
        "alert": {"title": "Hermes", "body": "Hermes needs your attention."},
        "mutable-content": 1,
    }
    if body.sound:
        aps["sound"] = "default"
    payload = {
        "aps": aps,
        "h_v": body.v,
        "class": body.notification_class,
        "nid": body.notification_id,
        "enc": body.preview_enc,
        "ct": body.preview_ct,
        "exp": body.expires_at_ms,
        "collapse": body.collapse_id,
        "sound": body.sound,
    }
    serialized = json.dumps(
        payload,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    # APNs' absolute regular-payload limit is 4,096. HRP/2 intentionally keeps
    # 196 bytes of headroom for operational safety and rejects at 3,901.
    if len(serialized) > 3_900:
        raise PayloadTooLarge(len(serialized))
    if len(serialized) > 4_096:  # defensive invariant if the budget changes
        raise PayloadTooLarge(len(serialized))
    return payload, serialized


class APNsClient:
    _REFRESH_AFTER_SECONDS = 50 * 60

    def __init__(self, settings: Settings, *, client: httpx.AsyncClient) -> None:
        if not settings.apns_configured:
            raise RuntimeError("APNs credentials are not configured")
        self._settings = settings
        self._client = client
        self._provider_token: str | None = None
        self._issued_at = 0.0

    def _jwt(self) -> str:
        now = time.time()
        if (
            self._provider_token is None
            or now - self._issued_at >= self._REFRESH_AFTER_SECONDS
        ):
            self._issued_at = now
            self._provider_token = jwt.encode(
                {"iss": self._settings.apns_team_id, "iat": int(now)},
                self._settings.apns_key_pem,
                algorithm="ES256",
                headers={"alg": "ES256", "kid": self._settings.apns_key_id},
            )
        return self._provider_token

    async def send(
        self,
        *,
        endpoint: APNsEndpoint,
        payload: bytes,
        collapse_id: str | None,
        apns_id: str,
        expires_at_ms: int,
    ) -> APNsResult:
        host = _SANDBOX_HOST if endpoint.environment == "sandbox" else _PRODUCTION_HOST
        headers = {
            "authorization": f"bearer {self._jwt()}",
            "apns-topic": endpoint.bundle_id,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-expiration": str(max(0, expires_at_ms // 1000)),
            "content-type": "application/json",
            "apns-id": apns_id,
        }
        if collapse_id is not None:
            headers["apns-collapse-id"] = collapse_id
        # One durable gateway reservation maps to exactly one provider call.
        # Retrying inside this client would bypass the per-binding attempt
        # ledger and its backoff; callers safely retry the same APNs identity.
        try:
            response = await self._client.post(
                f"{host}/3/device/{endpoint.token}",
                headers=headers,
                content=payload,
            )
        except httpx.HTTPError:
            return APNsResult(False, 0, retryable=True)
        if response.status_code == 200:
            return APNsResult(True, 200)
        reason = _reason(response)
        if response.status_code == 410 and reason in _PERMANENT_TOKEN_REASONS:
            return APNsResult(False, response.status_code, should_prune=True)
        if response.status_code == 403 or reason in _PROVIDER_REASONS:
            logger.error(
                "APNs provider configuration rejected push status=%s reason=%s environment=%s bundle=%s",
                response.status_code,
                reason,
                endpoint.environment,
                endpoint.bundle_id,
            )
            return APNsResult(False, response.status_code)
        if response.status_code < 500 and response.status_code != 429:
            return APNsResult(False, response.status_code)
        return APNsResult(
            False,
            response.status_code,
            retryable=True,
            retry_after_ms=_retry_after_ms(response),
        )


def _reason(response: httpx.Response) -> str | None:
    try:
        value = response.json()
    except Exception:
        return None
    reason = value.get("reason") if isinstance(value, dict) else None
    return reason if isinstance(reason, str) and len(reason) <= 80 else None


def _retry_after_ms(
    response: httpx.Response, *, now_seconds: float | None = None
) -> int | None:
    """Parse RFC Retry-After without allowing a provider to pin retries forever."""

    raw = response.headers.get("Retry-After")
    if raw is None:
        return None
    raw = raw.strip()
    if not raw or len(raw) > 128 or not raw.isascii():
        return None
    if raw.isdecimal():
        # Bound before multiplication so arbitrarily large decimal input stays
        # cheap even though Python integers themselves do not overflow.
        seconds = min(int(raw), MAX_APNS_RETRY_AFTER_MS // 1000)
        return seconds * 1000
    try:
        retry_at = parsedate_to_datetime(raw)
    except (TypeError, ValueError, OverflowError):
        return None
    if retry_at.tzinfo is None:
        return None
    now = time.time() if now_seconds is None else now_seconds
    delay_ms = max(0, math.ceil((retry_at.timestamp() - now) * 1000))
    return min(delay_ms, MAX_APNS_RETRY_AFTER_MS)
