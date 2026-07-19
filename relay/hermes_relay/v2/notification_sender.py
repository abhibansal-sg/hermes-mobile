"""Per-device encrypted notification orchestration."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import weakref
from collections.abc import Mapping
from dataclasses import replace
from typing import Any

from .crypto import encrypt_notification_preview
from .errors import Revoked
from .identity import RelayIdentity, relay_private_kem_generations
from .protocol import (
    NotificationClass,
    NotificationPreview,
    NotificationSendDescriptor,
    MAX_PREVIEW_PLAINTEXT_BYTES,
    b64url_encode,
    canonical_json,
)
from .push_client import PushGatewayClient, PushGatewayRejected
from .storage import NotificationOutboxRecord, RelayStorage


NOTIFICATION_DELIVERY_CONCURRENCY = 8


class NotificationSender:
    def __init__(
        self,
        storage: RelayStorage,
        identity: RelayIdentity,
        client: PushGatewayClient,
    ) -> None:
        self.storage = storage
        self.identity = identity
        self.client = client
        self._device_delivery_locks: weakref.WeakValueDictionary[
            str, asyncio.Lock
        ] = weakref.WeakValueDictionary()
        self._wake = asyncio.Event()

    async def bind_device(self, device_id: str, bind_token: str) -> str:
        existing = self.storage.push_binding(device_id)
        if existing is not None:
            return str(existing["binding_id"])
        classes = ["approval", "error", "update"]
        exchange = self.storage.prepare_push_binding_exchange(
            device_id=device_id,
            bind_token=bind_token,
            requested_classes=classes,
        )
        result = await self.client.exchange_binding(
            exchange.bind_token,
            exchange_id=exchange.exchange_id,
            requested_classes=list(exchange.requested_classes),
        )
        from .protocol import b64url_decode

        capability = b64url_decode(
            result["send_capability"], field="send_capability", exact_bytes=32
        )
        self.storage.complete_push_binding_exchange(
            device_id=device_id,
            exchange_id=exchange.exchange_id,
            binding_id=result["binding_id"],
            send_capability=capability,
            allowed_classes=result["allowed_classes"],
        )
        return str(result["binding_id"])

    async def send_to_device(
        self,
        device_id: str,
        preview: NotificationPreview,
        *,
        session_id: str | None = None,
        collapse_id: str | None = None,
        sound: bool = True,
        dedupe_key: str | None = None,
    ) -> dict[str, Any]:
        record, result = self.enqueue_to_device(
            device_id,
            preview,
            session_id=session_id,
            collapse_id=collapse_id,
            sound=sound,
            dedupe_key=dedupe_key,
        )
        if record is None:
            return result
        return await self._attempt(record)

    def enqueue_to_device(
        self,
        device_id: str,
        preview: NotificationPreview,
        *,
        session_id: str | None = None,
        collapse_id: str | None = None,
        sound: bool = True,
        dedupe_key: str | None = None,
    ) -> tuple[NotificationOutboxRecord | None, dict[str, Any]]:
        """Durably freeze a notification without performing network I/O.

        Gateway projection calls this synchronous local boundary so APNs or
        Push Gateway latency can never stall authoritative in-app frames.  A
        fixed-size background worker pool later sends the exact committed
        descriptor.
        """

        logical_key = dedupe_key or f"notification:{preview.notification_id}"
        existing = self.storage.notification_by_dedupe(device_id, logical_key)
        if existing is not None:
            if existing.state == "sent":
                return existing, {
                    "suppressed": False,
                    "accepted": True,
                    "deduplicated": True,
                    "state": "sent",
                }
            if existing.state != "pending":
                return None, {
                    "suppressed": True,
                    "reason": f"notification_{existing.state}",
                }
            self._wake.set()
            return existing, {
                "suppressed": False,
                "accepted": False,
                "queued": True,
                "deduplicated": True,
                "state": "pending",
            }
        device = self.storage.get_device(device_id)
        binding = self.storage.push_binding(device_id)
        if device is None or binding is None:
            return None, {"suppressed": True, "reason": "push_unavailable"}
        if preview.notification_class.value not in binding["allowed_classes"]:
            return None, {"suppressed": True, "reason": "class_not_allowed"}
        preview = fit_notification_preview(preview)
        sender_generation = device.relay_kem_generation
        if sender_generation == self.identity.kem_generation:
            sender_private_key = self.identity.kem_private
        else:
            sender_private_key = relay_private_kem_generations(self.storage).get(
                sender_generation
            )
            if sender_private_key is None:
                raise Revoked(
                    "Device has not acknowledged an available Agent KEM generation"
                )
        descriptor = encrypt_notification_preview(
            preview,
            recipient_public_key=device.preview_public,
            sender_private_key=sender_private_key,
            collapse_id=collapse_id,
            sound=sound,
        )
        record, created = self.storage.enqueue_notification(
            device_id=device_id,
            binding_id=str(binding["binding_id"]),
            session_id=session_id,
            dedupe_key=logical_key,
            descriptor=descriptor.to_dict(),
        )
        if created:
            self.storage.record_relay_encryption(sender_generation)
        self._wake.set()
        return record, {
            "suppressed": False,
            "accepted": False,
            "queued": True,
            "deduplicated": not created,
            "state": record.state,
        }

    async def _attempt(self, record: NotificationOutboxRecord) -> dict[str, Any]:
        """Deliver one committed row, retaining it on every ambiguous result."""

        lock = self._device_delivery_locks.setdefault(record.device_id, asyncio.Lock())
        async with lock:
            current = self.storage.notification_outbox_record(
                record.device_id, record.notification_id
            )
            if current is None:
                return {"suppressed": True, "reason": "notification_unavailable"}
            if current.state == "sent":
                return {
                    "suppressed": False,
                    "accepted": True,
                    "deduplicated": True,
                    "state": "sent",
                }
            if current.state != "pending":
                return {
                    "suppressed": True,
                    "reason": f"notification_{current.state}",
                }
            if current.expires_at_ms <= self.storage.current_time_ms():
                self.storage.expire_notifications()
                return {"suppressed": True, "reason": "notification_expired"}

            # Presence is scoped to the exact destination.  Crucially, the
            # notification is already durable: if iOS backgrounds without its
            # clear reaching us, the renewable lease expires and this same
            # ciphertext is delivered by the retry pump.
            lease_expires_at = (
                self.storage.foreground_lease_expires_at(
                    current.device_id, current.session_id
                )
                if current.session_id is not None
                else None
            )
            if lease_expires_at is not None:
                self.storage.defer_notification(
                    current.device_id,
                    current.notification_id,
                    until_ms=lease_expires_at,
                )
                return {
                    "suppressed": True,
                    "reason": "device_foreground",
                    "queued": True,
                }

            binding = self.storage.push_binding(current.device_id)
            if binding is None or binding["binding_id"] != current.binding_id:
                self.storage.mark_notification_failed(
                    current.device_id,
                    current.notification_id,
                    "binding_unavailable",
                    attempted=False,
                )
                return {"suppressed": True, "reason": "binding_unavailable"}
            descriptor = NotificationSendDescriptor.from_dict(current.descriptor)
            try:
                result = await self.client.send(
                    descriptor,
                    send_capability=binding["send_capability"],
                )
            except asyncio.CancelledError:
                raise
            except PushGatewayRejected as exc:
                if exc.retryable:
                    self.storage.mark_notification_retry(
                        current.device_id,
                        current.notification_id,
                        exc.code,
                    )
                    return {
                        "suppressed": False,
                        "accepted": False,
                        "queued": True,
                        "error": exc.code,
                    }
                self.storage.mark_notification_failed(
                    current.device_id,
                    current.notification_id,
                    exc.code,
                )
                return {
                    "suppressed": False,
                    "accepted": False,
                    "state": "failed",
                    "error": exc.code,
                }
            except Exception:
                self.storage.mark_notification_retry(
                    current.device_id,
                    current.notification_id,
                    "push_request_ambiguous",
                )
                return {
                    "suppressed": False,
                    "accepted": False,
                    "queued": True,
                    "error": "push_request_ambiguous",
                }

            if result.get("accepted") is True:
                self.storage.mark_notification_sent(
                    current.device_id, current.notification_id
                )
                return {"suppressed": False, **result, "state": "sent"}

            provider_status = result.get("provider_status")
            terminal = (
                result.get("endpoint_pruned") is True
                or result.get("status") == "permanent_rejected"
                or (
                    isinstance(provider_status, int)
                    and 400 <= provider_status < 500
                    and provider_status != 429
                )
            )
            if terminal:
                code = (
                    "endpoint_pruned"
                    if result.get("endpoint_pruned") is True
                    else "push_permanent_rejection"
                )
                self.storage.mark_notification_failed(
                    current.device_id, current.notification_id, code
                )
                return {"suppressed": False, **result, "state": "failed"}

            self.storage.mark_notification_retry(
                current.device_id,
                current.notification_id,
                "push_provider_retryable",
            )
            return {
                "suppressed": False,
                **result,
                "queued": True,
                "state": "pending",
            }

    async def flush_pending(self, *, limit: int = 256) -> list[dict[str, Any]]:
        """Drain exact descriptors concurrently, but serially per device."""

        grouped: dict[str, list[NotificationOutboxRecord]] = {}
        for record in self.storage.pending_notifications(limit=limit):
            grouped.setdefault(record.device_id, []).append(record)
        semaphore = asyncio.Semaphore(NOTIFICATION_DELIVERY_CONCURRENCY)

        async def drain_device(
            records: list[NotificationOutboxRecord],
        ) -> list[dict[str, Any]]:
            async with semaphore:
                return [await self._attempt(record) for record in records]

        batches = await asyncio.gather(
            *(drain_device(records) for records in grouped.values())
        )
        return [result for batch in batches for result in batch]

    async def wait_for_work(self, timeout_s: float) -> None:
        """Wait for an enqueue signal, with a timer for durable retry rows."""

        try:
            await asyncio.wait_for(self._wake.wait(), timeout=timeout_s)
        except TimeoutError:
            return
        finally:
            self._wake.clear()

    def enqueue_approval_request(
        self,
        *,
        session_id: str,
        request_id: str,
        title: str,
        body: str,
        expires_at_ms: int,
        destructive: bool,
        allowed_decisions: tuple[str, ...] = ("approve_once", "deny"),
        capabilities: Mapping[str, str] | None = None,
    ) -> dict[str, tuple[NotificationOutboxRecord | None, dict[str, Any]]]:
        """Mint and durably enqueue device-scoped approval previews."""

        if capabilities is None:
            capabilities = self.storage.create_approval_capabilities(
                request_id=request_id,
                session_id=session_id,
                expires_at_ms=expires_at_ms,
                allowed_decisions=allowed_decisions,
            )
        queued: dict[
            str, tuple[NotificationOutboxRecord | None, dict[str, Any]]
        ] = {}
        for device_id, capability in capabilities.items():
            device = self.storage.get_device(device_id)
            if device is None:
                continue
            preview, collapse = self._approval_preview(
                device_id=device_id,
                device_generation=device.kem_generation,
                capability=capability,
                session_id=session_id,
                request_id=request_id,
                title=title,
                body=body,
                expires_at_ms=expires_at_ms,
                destructive=destructive,
                allowed_decisions=allowed_decisions,
            )
            queued[device_id] = self.enqueue_to_device(
                device_id,
                preview,
                session_id=session_id,
                collapse_id=collapse,
                sound=True,
                dedupe_key=f"approval:{session_id}:{request_id}",
            )
        return queued

    async def send_approval_request(
        self,
        *,
        session_id: str,
        request_id: str,
        title: str,
        body: str,
        expires_at_ms: int,
        destructive: bool,
        allowed_decisions: tuple[str, ...] = ("approve_once", "deny"),
        capabilities: Mapping[str, str] | None = None,
    ) -> dict[str, dict[str, Any]]:
        """Mint and deliver one device-scoped approval capability per phone."""

        queued = self.enqueue_approval_request(
            session_id=session_id,
            request_id=request_id,
            title=title,
            body=body,
            expires_at_ms=expires_at_ms,
            destructive=destructive,
            allowed_decisions=allowed_decisions,
            capabilities=capabilities,
        )
        results: dict[str, dict[str, Any]] = {}
        for device_id, (record, result) in queued.items():
            results[device_id] = (
                await self._attempt(record) if record is not None else result
            )
        return results

    def _approval_preview(
        self,
        *,
        device_id: str,
        device_generation: int,
        capability: str,
        session_id: str,
        request_id: str,
        title: str,
        body: str,
        expires_at_ms: int,
        destructive: bool,
        allowed_decisions: tuple[str, ...],
    ) -> tuple[NotificationPreview, str]:
        # IDs and collapse handles reveal no session/request identity to the
        # content-blind Push Gateway.
        notification_id = "nid_" + b64url_encode(
            hmac.new(
                self.identity.sign_private,
                b"hrp2-approval-notification\x00"
                + session_id.encode("utf-8")
                + b"\x00"
                + request_id.encode("utf-8")
                + b"\x00"
                + device_id.encode("utf-8"),
                hashlib.sha256,
            ).digest()
        )
        thread_token = "thr_" + b64url_encode(
            hmac.new(
                self.identity.sign_private,
                b"hrp2-push-thread-token\x00" + session_id.encode("utf-8"),
                hashlib.sha256,
            ).digest()
        )
        collapse = b64url_encode(
            hashlib.sha256(
                b"hrp2-approval\x00"
                + request_id.encode("utf-8")
                + b"\x00"
                + device_id.encode("utf-8")
            ).digest()
        )
        return (
            NotificationPreview(
                notification_id=notification_id,
                notification_class=NotificationClass.APPROVAL,
                title=_preview_text(title, fallback="Approval required", maximum=200),
                body=_preview_text(
                    body,
                    fallback="Review this approval in Hermes",
                    maximum=700,
                ),
                thread_token=thread_token,
                category="HERMES_APPROVAL",
                expires_at_ms=expires_at_ms,
                action={
                    "request_id": request_id,
                    "session_id": session_id,
                    "capability": capability,
                    "allowed_decisions": list(allowed_decisions),
                    "destructive": destructive,
                    "device_id": device_id,
                    "device_generation": device_generation,
                },
            ),
            collapse,
        )

    async def revoke_device_binding(self, device_id: str) -> bool:
        binding = self.storage.push_binding(device_id)
        if binding is None:
            return False
        await self.client.revoke_binding(
            binding["binding_id"], send_capability=binding["send_capability"]
        )
        return self.storage.revoke_push_binding(device_id)

    async def reconcile_device_revocation(self, device_id: str) -> int:
        """Retry every Push tombstone for one fail-closed device.

        Binding/exchange capabilities stay protected at rest until the Push
        Gateway confirms revocation.  Each capability is attempted
        independently so one failed cleanup cannot starve the other.
        """

        confirmed = 0
        errors: list[Exception] = []
        for exchange in self.storage.pending_push_exchange_revocations():
            if exchange.device_id != device_id:
                continue
            try:
                await self.client.revoke_binding_exchange(
                    exchange.bind_token,
                    exchange_id=exchange.exchange_id,
                )
                if self.storage.confirm_push_exchange_remote_revocation(
                    exchange.device_id,
                    exchange.exchange_id,
                ):
                    confirmed += 1
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.storage.mark_push_exchange_revocation_failed(
                    exchange.device_id,
                    exchange.exchange_id,
                    type(exc).__name__,
                )
                errors.append(exc)

        for record in self.storage.pending_push_binding_revocations():
            if record.device_id != device_id:
                continue
            try:
                capability = self.storage.push_binding_revocation_capability(
                    record.binding_id
                )
                await self.client.revoke_binding(
                    record.binding_id,
                    send_capability=capability,
                )
                if self.storage.confirm_push_binding_remote_revocation(
                    record.binding_id
                ):
                    confirmed += 1
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.storage.mark_push_binding_revocation_failed(
                    record.binding_id,
                    type(exc).__name__,
                )
                errors.append(exc)

        self.storage.finish_confirmed_remote_credential_cleanup()
        if errors:
            raise errors[0]
        return confirmed

    async def revoke_all_authority(self) -> int:
        """Fail closed for Push opt-out, then confirm every remote tombstone.

        Queueing happens in one local transaction before network use.  A
        partial outage therefore leaves the old Push client configuration and
        protected cleanup capabilities available for an exact retry.
        Device and Hub authority are intentionally unaffected.
        """

        self.storage.queue_all_push_authority_revocation()
        device_ids = {
            record.device_id
            for record in self.storage.pending_push_binding_revocations()
        }
        device_ids.update(
            record.device_id
            for record in self.storage.pending_push_exchange_revocations()
        )
        confirmed = 0
        errors: list[Exception] = []
        for device_id in sorted(device_ids):
            try:
                confirmed += await self.reconcile_device_revocation(device_id)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                errors.append(exc)
        if errors:
            raise errors[0]
        if (
            self.storage.pending_push_binding_revocations()
            or self.storage.pending_push_exchange_revocations()
        ):
            raise RuntimeError("Push authority revocation remains pending")
        return confirmed


def _preview_text(value: str, *, fallback: str, maximum: int) -> str:
    text = value.strip() if isinstance(value, str) else ""
    text = text or fallback
    raw = text.encode("utf-8")
    if len(raw) <= maximum:
        return text
    return raw[:maximum].decode("utf-8", errors="ignore") or fallback


def fit_notification_preview(preview: NotificationPreview) -> NotificationPreview:
    """Fit title/body to the whole 1,200-byte authenticated plaintext budget.

    Notification IDs, expiry, category, and approval authority are immutable.
    Truncation is deterministic, Unicode-boundary safe, and performed before
    encryption/outbox commit so a valid event can never disappear between
    projection and durable notification delivery.
    """

    if _preview_size(preview) <= MAX_PREVIEW_PLAINTEXT_BYTES:
        return preview
    minimal = replace(preview, title="…", body="…")
    if _preview_size(minimal) > MAX_PREVIEW_PLAINTEXT_BYTES:
        # Preserve protocol authority fields and surface the same typed size
        # failure as NotificationPreview.to_bytes().
        minimal.to_bytes()
    with_title = replace(minimal, title=preview.title)
    if _preview_size(with_title) > MAX_PREVIEW_PLAINTEXT_BYTES:
        with_title = _fit_preview_field(
            minimal,
            field="title",
            original=preview.title,
            field_maximum=200,
        )
    fitted = _fit_preview_field(
        with_title,
        field="body",
        original=preview.body,
        field_maximum=1_200,
    )
    fitted.to_bytes()
    return fitted


def _fit_preview_field(
    base: NotificationPreview,
    *,
    field: str,
    original: str,
    field_maximum: int,
) -> NotificationPreview:
    full = replace(base, **{field: original})
    if _preview_size(full) <= MAX_PREVIEW_PLAINTEXT_BYTES:
        return full
    low = 0
    high = max(0, len(original) - 1)
    best = replace(base, **{field: "…"})
    while low <= high:
        middle = (low + high) // 2
        text = original[:middle] + "…"
        if (
            len(text.encode("utf-8")) <= field_maximum
            and _preview_size(replace(base, **{field: text}))
            <= MAX_PREVIEW_PLAINTEXT_BYTES
        ):
            best = replace(base, **{field: text})
            low = middle + 1
        else:
            high = middle - 1
    return best


def _preview_size(preview: NotificationPreview) -> int:
    return len(canonical_json(preview.to_dict()))


__all__ = ["NotificationSender", "fit_notification_preview"]
