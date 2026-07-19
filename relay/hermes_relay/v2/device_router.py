"""Per-device durable encryption, batching and independent send workers."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import random
import secrets
import time
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from .crypto import seal_authenticated_envelope
from .errors import Expired, MailboxFull, ProtocolError, RateLimited, Revoked
from .hub_client import HubClient
from .identity import RelayIdentity, relay_private_kem_generations
from .projection import V2Projection
from .protocol import (
    HPKEDirection,
    HPKEPurpose,
    OuterEnvelope,
    OuterHeader,
    SecureMessage,
    SecureMessageKind,
    TransportClass,
    b64url_encode,
)
from .storage import DEFAULT_MAILBOX_TTL_MS, DeviceRecord, OutboxRecord, RelayStorage


_REALTIME_FRAME_KINDS = frozenset({"turn.started", "item.started", "item.delta"})


def frame_transport_class(frame: Mapping[str, Any]) -> TransportClass:
    """Select the HRP/2 delivery lane from one projected frame.

    Only transient lifecycle frames are best-effort realtime.  Full terminal
    state, interactive gates, status/title changes, and unknown future frames
    stay durable so an offline device can converge safely.
    """

    kind = str(frame.get("kind", ""))
    body = frame.get("body")
    transient_thinking = (
        kind == "status"
        and isinstance(body, Mapping)
        and body.get("kind") == "thinking"
    )
    return (
        TransportClass.REALTIME
        if kind in _REALTIME_FRAME_KINDS or transient_thinking
        else TransportClass.STATE
    )


@dataclass(frozen=True, slots=True)
class DeviceSenderStatus:
    device_id: str
    running: bool
    wake_queue_size: int
    last_error_code: str | None


class DeviceSender:
    """A bounded wake queue driving one device's durable outbox.

    Work itself is in SQLite before :meth:`offer` is called.  A full wake queue
    therefore coalesces signals rather than losing frames.  No send on this
    worker can block another device's worker.
    """

    def __init__(
        self,
        device_id: str,
        storage: RelayStorage,
        hub: HubClient,
        *,
        max_pending: int = 256,
        clock_ms=lambda: time.time_ns() // 1_000_000,
        retry_initial_s: float = 0.25,
        retry_max_s: float = 30.0,
        jitter=lambda delay: random.uniform(delay * 0.8, delay * 1.2),
    ) -> None:
        self.device_id = device_id
        self.storage = storage
        self.hub = hub
        self.queue: asyncio.Queue[str] = asyncio.Queue(max_pending)
        self._task: asyncio.Task[None] | None = None
        self._closing = False
        self.last_error_code: str | None = None
        self._clock = clock_ms
        self._retry_initial = retry_initial_s
        self._retry_max = retry_max_s
        self._jitter = jitter

    def start(self) -> None:
        if self._task is None or self._task.done():
            self._closing = False
            self._task = asyncio.create_task(
                self._run(), name=f"relay.v2.send.{self.device_id}"
            )
            self.offer("startup")

    def offer(self, message_id: str) -> bool:
        try:
            self.queue.put_nowait(message_id)
            return True
        except asyncio.QueueFull:
            return False

    async def flush_once(self) -> int:
        sent = 0
        # Hub-accepted rows remain until the E2EE application receipt, but do
        # not need to be resent on every wake.  A crash before this state change
        # leaves the row pending, so ambiguous HTTP acceptance is still retried
        # with the identical envelope/message ID.
        rows = [
            row
            for row in self.storage.pending_outbox(self.device_id)
            if row.state == "pending"
        ]
        for row in rows:
            device = self.storage.get_device(self.device_id)
            if device is None:
                self.last_error_code = "REVOKED"
                self.storage.mark_send_terminal(
                    self.device_id, row.message_id, "REVOKED"
                )
                continue
            if row.expires_at_ms <= self._clock():
                self.last_error_code = "EXPIRED"
                if row.message_class == TransportClass.REALTIME.value:
                    self.storage.discard_realtime(self.device_id, row.message_id)
                else:
                    self.storage.mark_send_terminal(
                        self.device_id, row.message_id, "EXPIRED"
                    )
                continue
            try:
                envelope = OuterEnvelope.from_dict(row.envelope)
                accepted = await self.hub.send_envelope(envelope)
                if row.completion_policy == "hub_accept":
                    if not isinstance(accepted, Mapping) or not (
                        accepted.get("stored") is True
                        or accepted.get("deduplicated") is True
                    ):
                        raise ConnectionError(
                            "Hub did not prove durable receipt acceptance"
                        )
                    self.storage.complete_hub_accept_delivery_receipt(
                        self.device_id, row.message_id
                    )
                elif (
                    envelope.message_class == TransportClass.REALTIME
                    and isinstance(accepted, Mapping)
                    and accepted.get("stored") is False
                ):
                    self.storage.discard_realtime(self.device_id, row.message_id)
                else:
                    self.storage.mark_hub_accepted(self.device_id, row.message_id)
                self.last_error_code = None
                sent += 1
            except asyncio.CancelledError:
                raise
            except (Expired, Revoked) as exc:
                self.last_error_code = exc.code.value
                if row.message_class == TransportClass.REALTIME.value:
                    self.storage.discard_realtime(self.device_id, row.message_id)
                else:
                    self.storage.mark_send_terminal(
                        self.device_id, row.message_id, exc.code.value
                    )
                continue
            except (MailboxFull, RateLimited) as exc:
                self.last_error_code = exc.code.value
                if row.message_class == TransportClass.REALTIME.value:
                    self.storage.discard_realtime(self.device_id, row.message_id)
                    continue
                self.storage.mark_send_failed(
                    self.device_id, row.message_id, exc.code.value
                )
                break
            except ProtocolError as exc:
                self.last_error_code = exc.code.value
                if row.message_class == TransportClass.REALTIME.value:
                    self.storage.discard_realtime(self.device_id, row.message_id)
                else:
                    self.storage.mark_send_terminal(
                        self.device_id, row.message_id, exc.code.value
                    )
                continue
            except Exception:
                self.last_error_code = "TRANSPORT_UNAVAILABLE"
                if row.message_class == TransportClass.REALTIME.value:
                    self.storage.discard_realtime(self.device_id, row.message_id)
                    continue
                self.storage.mark_send_failed(
                    self.device_id, row.message_id, "TRANSPORT_UNAVAILABLE"
                )
                break
        return sent

    async def _run(self) -> None:
        retry_delay: float | None = None
        while not self._closing:
            got_item = False
            try:
                if retry_delay is None:
                    await self.queue.get()
                    got_item = True
                else:
                    try:
                        await asyncio.wait_for(
                            self.queue.get(),
                            timeout=max(0.001, self._jitter(retry_delay)),
                        )
                        got_item = True
                    except TimeoutError:
                        # Timer wake: the durable outbox is the source of work.
                        pass
            except asyncio.CancelledError:
                break
            if got_item:
                self.queue.task_done()
                # Coalesce every queued hint; each row is discovered from the
                # durable outbox, so message IDs need not be retained here.
                while True:
                    try:
                        self.queue.get_nowait()
                    except asyncio.QueueEmpty:
                        break
                    else:
                        self.queue.task_done()
            await self.flush_once()
            pending = any(
                row.state == "pending"
                for row in self.storage.pending_outbox(self.device_id, limit=1)
            )
            if pending and self.last_error_code is not None:
                retry_delay = (
                    self._retry_initial
                    if retry_delay is None
                    else min(self._retry_max, retry_delay * 2)
                )
            else:
                retry_delay = None

    async def close(self) -> None:
        self._closing = True
        if self._task is not None:
            self._task.cancel()
            await asyncio.gather(self._task, return_exceptions=True)
            self._task = None

    def status(self) -> DeviceSenderStatus:
        return DeviceSenderStatus(
            self.device_id,
            self._task is not None and not self._task.done(),
            self.queue.qsize(),
            self.last_error_code,
        )


class DeviceRouter:
    def __init__(
        self,
        storage: RelayStorage,
        identity: RelayIdentity,
        hub: HubClient,
        *,
        relay_route: str,
        projection: V2Projection | None = None,
        clock_ms=lambda: time.time_ns() // 1_000_000,
        max_pending_per_device: int = 256,
        retry_initial_s: float = 0.25,
        retry_max_s: float = 30.0,
        retry_jitter=lambda delay: random.uniform(delay * 0.8, delay * 1.2),
    ) -> None:
        self.storage = storage
        self.identity = identity
        self.hub = hub
        self.relay_route = relay_route
        self.projection = projection or V2Projection(storage)
        self._clock = clock_ms
        self._max_pending = max_pending_per_device
        self._retry_initial = retry_initial_s
        self._retry_max = retry_max_s
        self._retry_jitter = retry_jitter
        self._senders: dict[str, DeviceSender] = {}

    def start(self) -> None:
        for device in self.storage.active_devices():
            self._sender(device.device_id).start()

    def _sender(self, device_id: str) -> DeviceSender:
        sender = self._senders.get(device_id)
        if sender is None:
            sender = DeviceSender(
                device_id,
                self.storage,
                self.hub,
                max_pending=self._max_pending,
                clock_ms=self._clock,
                retry_initial_s=self._retry_initial,
                retry_max_s=self._retry_max,
                jitter=self._retry_jitter,
            )
            self._senders[device_id] = sender
        return sender

    def publish(self, source_frame: Any) -> int:
        """Project once, persist/encrypt per subscriber, and return fan-out count."""

        frame = self.project(source_frame)
        if frame is None:
            return 0
        return self.publish_frames(
            str(frame.get("sid", "")),
            [frame],
            message_class=frame_transport_class(frame),
        )

    def project(self, source_frame: Any) -> dict[str, Any] | None:
        """Canonicalize a Gateway session ID and durably project one frame."""

        source_sid = (
            source_frame.get("sid", "")
            if isinstance(source_frame, Mapping)
            else getattr(source_frame, "sid", "")
        )
        canonical_sid = self.storage.origin_session_id(str(source_sid))
        if source_sid and canonical_sid != source_sid:
            if isinstance(source_frame, Mapping):
                source_frame = {**source_frame, "sid": canonical_sid}
            else:
                source_frame = {
                    "sid": canonical_sid,
                    "turn": getattr(source_frame, "turn", None),
                    "kind": getattr(source_frame, "kind", ""),
                    "body": dict(getattr(source_frame, "body", {}) or {}),
                }
        return self.projection.apply(source_frame)

    def publish_frames(
        self,
        session_id: str,
        frames: Sequence[Mapping[str, Any]],
        *,
        message_class: TransportClass = TransportClass.STATE,
    ) -> int:
        count = 0
        for device_id in self.storage.subscribed_devices(session_id):
            device = self.storage.get_device(device_id)
            if device is None:
                continue
            record = self._enqueue_frame_batch(
                device, frames, message_class=message_class
            )
            sender = self._sender(device_id)
            sender.start()
            sender.offer(record.message_id)
            count += 1
        return count

    def publish_frames_to_device(
        self,
        device_id: str,
        frames: Sequence[Mapping[str, Any]],
        *,
        message_class: TransportClass = TransportClass.STATE,
    ) -> bool:
        """Encrypt one already-projected batch for exactly one destination."""

        device = self.storage.get_device(device_id)
        if device is None:
            return False
        record = self._enqueue_frame_batch(
            device,
            frames,
            message_class=message_class,
        )
        sender = self._sender(device_id)
        sender.start()
        sender.offer(record.message_id)
        return True

    def send_secure_message(
        self,
        device_id: str,
        kind: SecureMessageKind,
        body: Mapping[str, Any],
        *,
        message_class: TransportClass = TransportClass.CONTROL,
        ttl_ms: int = DEFAULT_MAILBOX_TTL_MS,
    ) -> str:
        device = self.storage.get_device(device_id)
        if device is None:
            raise ValueError("device is not active")
        at = self._clock()
        expiry = at + ttl_ms
        envelope = self._seal(
            device,
            kind=kind,
            body=body,
            message_class=message_class,
            expires_at_ms=expiry,
        )
        record = self.storage.enqueue_envelope(
            device_id,
            envelope.to_dict(),
            message_class=message_class.value,
            expires_at_ms=expiry,
        )
        sender = self._sender(device_id)
        sender.start()
        sender.offer(record.message_id)
        return record.message_id

    def send_delivery_receipt(self, device_id: str, inbound_message_id: str) -> str:
        """Queue one exact authenticated receipt for a committed inbound rotate.

        Unlike ordinary Agent-to-device control messages, this receipt is
        transport-complete once the Hub proves it stored (or deduplicated) the
        ciphertext.  The durable semantic binding prevents replay from ever
        manufacturing a new message ID or ciphertext.
        """

        existing = self.storage.inbound_delivery_receipt(device_id, inbound_message_id)
        if existing is not None:
            self.reoffer_delivery_receipt(device_id, inbound_message_id)
            return existing.outbound_message_id
        device = self.storage.get_device(device_id)
        if device is None:
            raise ValueError("device is not active")
        at = self._clock()
        expiry = at + DEFAULT_MAILBOX_TTL_MS
        envelope = self._seal(
            device,
            kind=SecureMessageKind.DELIVERY_RECEIPT,
            body={"mid": inbound_message_id},
            message_class=TransportClass.CONTROL,
            expires_at_ms=expiry,
        )
        link, record, _created = self.storage.enqueue_inbound_delivery_receipt(
            device_id,
            inbound_message_id,
            envelope.to_dict(),
            message_class=TransportClass.CONTROL.value,
            expires_at_ms=expiry,
        )
        if record is not None:
            sender = self._sender(device_id)
            sender.start()
            sender.offer(record.message_id)
        return link.outbound_message_id

    def reoffer_delivery_receipt(
        self, device_id: str, inbound_message_id: str
    ) -> str | None:
        """Wake the exact pre-existing receipt, without minting one on replay."""

        link = self.storage.inbound_delivery_receipt(device_id, inbound_message_id)
        if link is None:
            return None
        if link.state == "pending":
            record = self.storage.outbox_record(device_id, link.outbound_message_id)
            if record is None or record.completion_policy != "hub_accept":
                raise RuntimeError("pending delivery receipt lost its durable envelope")
            sender = self._sender(device_id)
            sender.start()
            sender.offer(record.message_id)
        return link.outbound_message_id

    def enqueue_checkpoint(self, device_id: str, session_id: str) -> OutboxRecord:
        device = self.storage.get_device(device_id)
        if device is None:
            raise ValueError("device is not active")
        expiry = self._clock() + DEFAULT_MAILBOX_TTL_MS

        def factory(
            stream_id: str,
            through_seq: int,
            checkpoint_revision: int,
        ) -> Mapping[str, Any]:
            checkpoint = self.projection.checkpoint(
                session_id,
                stream_id=stream_id,
                through_seq=through_seq,
                snapshot_revision=checkpoint_revision,
            )
            return self._seal(
                device,
                kind=SecureMessageKind.CHECKPOINT,
                body=checkpoint,
                message_class=TransportClass.STATE,
                expires_at_ms=expiry,
                collapse=self._checkpoint_collapse(device, session_id),
            ).to_dict()

        record = self.storage.enqueue_stream_checkpoint(
            device.device_id,
            factory,
            message_class=TransportClass.STATE.value,
            expires_at_ms=expiry,
        )
        sender = self._sender(device_id)
        sender.start()
        sender.offer(record.message_id)
        return record

    def _enqueue_frame_batch(
        self,
        device: DeviceRecord,
        frames: Sequence[Mapping[str, Any]],
        *,
        message_class: TransportClass = TransportClass.STATE,
    ) -> OutboxRecord:
        expiry = self._clock() + DEFAULT_MAILBOX_TTL_MS

        def factory(
            stream_id: str, first_seq: int, exact_frames: Sequence[Mapping[str, Any]]
        ):
            body = {
                "stream_id": stream_id,
                "first_seq": first_seq,
                "frames": [dict(frame) for frame in exact_frames],
            }
            return self._seal(
                device,
                kind=SecureMessageKind.FRAME_BATCH,
                body=body,
                message_class=message_class,
                expires_at_ms=expiry,
            ).to_dict()

        return self.storage.enqueue_frames(
            device.device_id,
            frames,
            factory,
            message_class=message_class.value,
            expires_at_ms=expiry,
        )

    def _seal(
        self,
        device: DeviceRecord,
        *,
        kind: SecureMessageKind,
        body: Mapping[str, Any],
        message_class: TransportClass,
        expires_at_ms: int,
        collapse: str | None = None,
    ) -> OuterEnvelope:
        mid = b64url_encode(secrets.token_bytes(16))
        header = OuterHeader(
            src=self.relay_route,
            dst=device.route,
            mid=mid,
            message_class=message_class,
            expires_at_ms=expires_at_ms,
            recipient_key_generation=device.kem_generation,
            collapse=collapse,
        )
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
        message = SecureMessage(
            mid=mid,
            kind=kind,
            sender_key_generation=sender_generation,
            created_at_ms=self._clock(),
            expires_at_ms=expires_at_ms,
            body=dict(body),
        )
        envelope = seal_authenticated_envelope(
            header,
            message,
            recipient_public_key=device.kem_public,
            sender_private_key=sender_private_key,
            signing_private_key=self.identity.sign_private,
            purpose=(
                HPKEPurpose.CHAT
                if kind in {SecureMessageKind.FRAME_BATCH, SecureMessageKind.CHECKPOINT}
                else HPKEPurpose.CONTROL
            ),
            direction=HPKEDirection.AGENT_TO_DEVICE,
        )
        self.storage.record_relay_encryption(sender_generation)
        return envelope

    def _checkpoint_collapse(self, device: DeviceRecord, session_id: str) -> str:
        """Return a stable opaque token for one device/session checkpoint."""

        return b64url_encode(
            hmac.new(
                self.identity.sign_private,
                b"hrp2-checkpoint\x00"
                + device.device_id.encode("utf-8")
                + b"\x00"
                + session_id.encode("utf-8"),
                hashlib.sha256,
            ).digest()
        )

    async def close(self) -> None:
        await asyncio.gather(
            *(sender.close() for sender in self._senders.values()),
            return_exceptions=True,
        )
        self._senders.clear()

    def status(self) -> list[DeviceSenderStatus]:
        return [sender.status() for sender in self._senders.values()]


__all__ = [
    "DeviceRouter",
    "DeviceSender",
    "DeviceSenderStatus",
    "frame_transport_class",
]
