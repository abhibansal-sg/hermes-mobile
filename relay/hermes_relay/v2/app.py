"""HRP/2 composition root for the trusted Agent Relay process."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import secrets
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from ..bus import TOPIC_GATEWAY_EVENTS, TOPIC_RELAY_FRAMES, EventBus
from ..gateway_client import GatewayClient, GatewayConfig
from ..reframer import Reframer
from ..secure_files import read_secure_text_file
from ..types import Frame, FrameKind
from .crypto import generate_x25519_key_pair
from .device_router import DeviceRouter, frame_transport_class
from .enrollment import AgentEnrollmentManager
from .hub_client import Ed25519RequestAuthenticator, HubClient, HubConfig
from .identity import RelayIdentity, load_or_create_identity
from .inbound import InboundProcessor
from .notification_sender import NotificationSender
from .pairing import PairingManager
from .projection import V2Projection
from .reframer_state import V2ReframerStore
from .protection import CredentialProtectionError, platform_credential_protector
from .push_client import PushGatewayClient, PushGatewayConfig
from .revocation import DeviceRevoker
from .rpc import RPCDispatcher
from .protocol import (
    NotificationClass,
    NotificationPreview,
    SecureMessageKind,
    TransportClass,
    MAX_WIRE_INTEGER,
    b64url_encode,
    canonical_json,
)
from .storage import (
    DEFAULT_MAILBOX_TTL_MS,
    RelayStorage,
    StorageConflict,
    StorageExpired,
)


_log = logging.getLogger("hermes_relay.v2.app")

KEY_ROTATION_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1_000
KEY_ROTATION_MAX_MESSAGES = 10_000
KEY_ROTATION_GRACE_MS = 24 * 60 * 60 * 1_000
KEY_MAINTENANCE_INTERVAL_S = 60.0
FRAME_BATCH_MAX_WAIT_S = 0.050
FRAME_BATCH_MAX_BYTES = 32 * 1024
NOTIFICATION_RETRY_INTERVAL_S = 1.0
READINESS_HEARTBEAT_INTERVAL_S = 5.0
READINESS_RETRY_INTERVAL_S = 1.0


def frame_batch_plaintext_size(frames: list[dict[str, Any]]) -> int:
    """Conservatively size the complete canonical inner HRP/2 plaintext.

    The app batcher runs before per-device stream sequence allocation, so it
    uses the exact generated token widths and maximum integer widths.  Actual
    encrypted batches are therefore never larger than this estimate merely
    because the ``frame_batch``/``SecureMessage`` wrapper was omitted.
    """

    return len(
        canonical_json({
            "v": 2,
            "mid": "A" * 22,
            "kind": SecureMessageKind.FRAME_BATCH.value,
            "sender_key_generation": (1 << 32) - 1,
            "created_at_ms": MAX_WIRE_INTEGER,
            "expires_at_ms": MAX_WIRE_INTEGER,
            "body": {
                "stream_id": "str_" + "A" * 22,
                "first_seq": MAX_WIRE_INTEGER,
                "frames": frames,
            },
        })
    )


@dataclass(frozen=True, slots=True)
class V2RelayConfig:
    gateway: GatewayConfig
    hub_url: str
    push_url: str | None = None
    state_directory: Path | None = None
    allow_insecure_local_services: bool = False
    hub_enrollment_token_file: Path | None = None


class V2RelayApp:
    def __init__(
        self,
        config: V2RelayConfig,
        *,
        storage: RelayStorage,
        identity: RelayIdentity,
        relay_route: str,
        hub: HubClient,
        push: PushGatewayClient | None,
    ) -> None:
        self.config = config
        self.storage = storage
        self.identity = identity
        self.relay_route = relay_route
        self.hub = hub
        self.push = push
        self.bus = EventBus()
        self.session_store = V2ReframerStore()
        self.gateway = GatewayClient(
            config.gateway,
            self.bus,
            owned_session_callback=storage.own_session,
            reliable_events=True,
        )
        self.gateway.restore_owned_sessions(storage.owned_sessions())
        self.reframer = Reframer(
            self.bus,
            self.session_store,
            reliable_output=True,
            max_contexts=self.session_store.max_sessions,
        )
        self.projection = V2Projection(storage)
        self.router = DeviceRouter(
            storage,
            identity,
            hub,
            relay_route=relay_route,
            projection=self.projection,
            clock_ms=storage.current_time_ms,
        )
        self.notifications = (
            NotificationSender(storage, identity, push) if push is not None else None
        )
        self.pairing = PairingManager(
            storage,
            identity,
            hub_url=config.hub_url,
            relay_route=relay_route,
            hub_client=hub,
            notification_sender=self.notifications,
        )
        self.revoker = DeviceRevoker(storage, hub, self.notifications)
        self.dispatcher = RPCDispatcher(self.gateway, storage, self.router)
        self.inbound = InboundProcessor(
            storage,
            hub,
            self.dispatcher,
            relay_route=relay_route,
            pairing=self.pairing,
            revoke_device=self.revoker.revoke,
        )
        self._tasks: dict[str, asyncio.Task[None]] = {}
        self._closing = False
        self._running = False
        self._shown_pair_claims: set[str] = set()
        self._restart_recovery_pending = True

    @classmethod
    async def create(cls, config: V2RelayConfig) -> "V2RelayApp":
        protector = platform_credential_protector()
        storage = RelayStorage(
            config.state_directory,
            credential_protector=protector,
        )
        identity = load_or_create_identity(storage, protector=protector)
        # The bootstrap endpoint is unauthenticated and ignores route_id.  A
        # stable local identifier keeps HubConfig valid without inventing an
        # ephemeral remote route or rotating the Agent identity.
        bootstrap = HubClient(
            HubConfig(
                config.hub_url,
                identity.relay_instance_id,
                allow_insecure_local=config.allow_insecure_local_services,
            )
        )
        push: PushGatewayClient | None = None
        try:
            enrollment = await AgentEnrollmentManager(
                storage, identity, bootstrap
            ).ensure_provisional()
        except Exception:
            storage.close()
            raise
        finally:
            await bootstrap.close()
        if enrollment.route_id is None:
            storage.close()
            raise RuntimeError("Hub enrollment did not return a route")
        authenticator = Ed25519RequestAuthenticator(
            enrollment.route_id, identity.sign_private
        )
        hub = HubClient(
            HubConfig(
                config.hub_url,
                enrollment.route_id,
                allow_insecure_local=config.allow_insecure_local_services,
            ),
            authenticator=authenticator,
        )
        try:
            if (
                enrollment.state != "active"
                and config.hub_enrollment_token_file is not None
            ):
                operator_token = read_protected_token_file(
                    config.hub_enrollment_token_file,
                    label="Hub operator enrollment token",
                )
                enrollment = await AgentEnrollmentManager(
                    storage, identity, hub
                ).activate_with_operator_token(enrollment, operator_token)
            push = (
                PushGatewayClient(
                    PushGatewayConfig(
                        config.push_url,
                        allow_insecure_local=config.allow_insecure_local_services,
                    )
                )
                if config.push_url is not None
                else None
            )
            app = cls(
                config,
                storage=storage,
                identity=identity,
                relay_route=enrollment.route_id,
                hub=hub,
                push=push,
            )
            await app.prepare_startup_maintenance()
            return app
        except Exception:
            if push is not None:
                await push.close()
            await hub.close()
            storage.close()
            raise

    async def run(
        self,
        *,
        readiness_callback: Callable[[str | None], None] | None = None,
    ) -> None:
        self._closing = False
        self._running = True
        self.router.start()
        self._recover_restart_projection()
        self._tasks = {
            "reframer": asyncio.create_task(
                self.reframer.run(), name="relay.v2.reframer"
            ),
            "frames": asyncio.create_task(self._frame_pump(), name="relay.v2.frames"),
            "inbound": asyncio.create_task(self.inbound.run(), name="relay.v2.inbound"),
            "pairing": asyncio.create_task(
                self._pairing_pump(), name="relay.v2.pairing"
            ),
            "keys": asyncio.create_task(
                self._key_maintenance_pump(), name="relay.v2.key-maintenance"
            ),
            "remote-revocations": asyncio.create_task(
                self._remote_revocation_pump(),
                name="relay.v2.remote-revocations",
            ),
        }
        if self.notifications is not None:
            self._tasks["notifications"] = asyncio.create_task(
                self._notification_pump(), name="relay.v2.notifications"
            )
        for _ in range(10_000):
            if (
                self.bus.subscriber_count(TOPIC_GATEWAY_EVENTS) >= 1
                and self.bus.subscriber_count(TOPIC_RELAY_FRAMES) >= 1
            ):
                break
            if any(task.done() for task in self._tasks.values()):
                break
            await asyncio.sleep(0)
        self._tasks["gateway"] = asyncio.create_task(
            self.gateway.run(), name="relay.v2.gateway"
        )
        try:
            if readiness_callback is not None:
                await self._prove_service_ready()
                readiness_callback(self.relay_route)
                self._tasks["readiness"] = asyncio.create_task(
                    self._readiness_pump(readiness_callback),
                    name="relay.v2.readiness",
                )
            done, _ = await asyncio.wait(
                self._tasks.values(), return_when=asyncio.FIRST_COMPLETED
            )
        finally:
            if readiness_callback is not None:
                try:
                    readiness_callback(None)
                except Exception:
                    _log.warning("Relay readiness marker cleanup failed", exc_info=True)
            await self.close()
        for task in done:
            if not task.cancelled() and task.exception() is not None:
                raise task.exception()  # type: ignore[misc]

    async def _prove_service_ready(self) -> None:
        """Prove both trusted upstreams after Gateway session restoration."""

        gateway_timeout = (
            self.config.gateway.connect_timeout_s
            + self.config.gateway.rpc_timeout_s
        )
        operational = getattr(self.gateway, "_operational", None)
        gateway_task = self._tasks.get("gateway")
        if not isinstance(operational, asyncio.Event) or gateway_task is None:
            raise ConnectionError("Gateway readiness state is unavailable")
        waiter = asyncio.create_task(operational.wait())
        try:
            done, _ = await asyncio.wait(
                {waiter, gateway_task},
                timeout=gateway_timeout,
                return_when=asyncio.FIRST_COMPLETED,
            )
            if waiter not in done or not operational.is_set():
                if gateway_task in done and not gateway_task.cancelled():
                    error = gateway_task.exception()
                    if error is not None:
                        raise ConnectionError(
                            "Gateway connection task terminated"
                        ) from error
                raise TimeoutError("Gateway did not become operational")
        finally:
            if not waiter.done():
                waiter.cancel()
                await asyncio.gather(waiter, return_exceptions=True)
        await asyncio.wait_for(
            self.gateway.session_list(),
            timeout=self.config.gateway.rpc_timeout_s,
        )
        proof = await asyncio.wait_for(
            self.hub.prove_route(),
            timeout=self.hub.config.request_timeout_s + 1.0,
        )
        enrollment = self.storage.latest_agent_enrollment()
        if (
            enrollment is None
            or enrollment.route_id != self.relay_route
            or proof != {
                "route_id": self.relay_route,
                "status": enrollment.state,
            }
        ):
            raise ConnectionError("Hub route readiness proof changed")
        if enrollment.state == "active":
            await asyncio.wait_for(
                self.hub.probe_receive_ready(),
                timeout=self.hub.config.request_timeout_s + 1.0,
            )
        elif enrollment.state != "provisional":
            raise ConnectionError("Hub route is not usable")
        if self.push is not None:
            await asyncio.wait_for(
                self.push.probe_ready(),
                timeout=self.push.config.timeout_s + 1.0,
            )

    async def _readiness_pump(
        self, callback: Callable[[str | None], None]
    ) -> None:
        """Keep the process-bound marker fresh only while both links work."""

        while not self._closing:
            await asyncio.sleep(READINESS_HEARTBEAT_INTERVAL_S)
            if self._closing:
                break
            try:
                await self._prove_service_ready()
                callback(self.relay_route)
            except asyncio.CancelledError:
                raise
            except Exception:
                try:
                    callback(None)
                except Exception:
                    _log.warning(
                        "Relay readiness marker invalidation failed", exc_info=True
                    )
                if self._closing:
                    break
                await asyncio.sleep(READINESS_RETRY_INTERVAL_S)

    def _recover_restart_projection(self) -> None:
        """Retire uncorrelatable live items and queue replacement snapshots."""

        if not self._restart_recovery_pending:
            return
        self.storage.clear_all_presence()
        subscriptions = self.storage.active_subscriptions()
        session_ids = {session_id for _device_id, session_id in subscriptions}
        for origin, live in self.storage.owned_sessions().items():
            session_ids.add(origin)
            session_ids.add(live)
        for session_id in sorted(session_ids):
            self.storage.retire_in_progress_items(session_id)
        for device_id, session_id in subscriptions:
            self.router.enqueue_checkpoint(device_id, session_id)
        self._restart_recovery_pending = False

    async def _frame_pump(self) -> None:
        # Gateway events are authoritative input. The reliable Gateway and
        # Reframer pumps await this bounded queue instead of dropping frames or
        # growing memory without limit. This pump performs no Push network I/O,
        # so backpressure covers only local projection/commit work.
        subscription = self.bus.subscribe(TOPIC_RELAY_FRAMES)
        pending: list[dict[str, Any]] = []
        pending_sid = ""
        pending_bytes = 0
        deadline: float | None = None

        def flush() -> None:
            nonlocal pending, pending_sid, pending_bytes, deadline
            if pending:
                self.router.publish_frames(
                    pending_sid,
                    pending,
                    message_class=TransportClass.REALTIME,
                )
            pending = []
            pending_sid = ""
            pending_bytes = 0
            deadline = None

        try:
            while True:
                if deadline is None:
                    frame = await subscription.get()
                else:
                    try:
                        frame = await asyncio.wait_for(
                            subscription.get(),
                            timeout=max(
                                0.0001, deadline - asyncio.get_running_loop().time()
                            ),
                        )
                    except TimeoutError:
                        flush()
                        continue
                if (
                    isinstance(frame, Frame)
                    and frame.kind == FrameKind.APPROVAL_REQUEST
                ):
                    flush()
                    await self._deliver_approval(frame)
                    continue
                projected = self.router.project(frame)
                if projected is None:
                    continue
                lane = frame_transport_class(projected)
                sid = str(projected.get("sid", ""))
                if lane is TransportClass.REALTIME:
                    if pending and sid != pending_sid:
                        flush()
                    candidate_size = frame_batch_plaintext_size([*pending, projected])
                    if pending and candidate_size > FRAME_BATCH_MAX_BYTES:
                        flush()
                        candidate_size = frame_batch_plaintext_size([projected])
                    if not pending:
                        pending_sid = sid
                        deadline = (
                            asyncio.get_running_loop().time() + FRAME_BATCH_MAX_WAIT_S
                        )
                    pending.append(projected)
                    pending_bytes = candidate_size
                    if pending_bytes >= FRAME_BATCH_MAX_BYTES:
                        flush()
                else:
                    # Terminal, interactive, title and durable status frames
                    # flush preceding deltas and are never delayed by the
                    # coalescing window.
                    flush()
                    self.router.publish_frames(
                        sid,
                        [projected],
                        message_class=lane,
                    )
                    if isinstance(frame, Frame):
                        await self._notify_terminal_frame(frame)
        finally:
            subscription.close()

    async def _deliver_approval(self, frame: Frame) -> None:
        """Mint once, then encrypt each device's distinct in-app authority."""

        body = frame.body or {}
        session_id = self.storage.origin_session_id(frame.sid)
        if not self._owns_session(frame.sid, session_id):
            return
        request_id = body.get("request_id") or body.get("approval_id") or body.get("id")
        if not isinstance(request_id, str) or not request_id:
            return
        expires = body.get("expires_at_ms")
        if isinstance(expires, bool) or not isinstance(expires, int):
            expires = self.storage.current_time_ms() + 5 * 60 * 1_000
        allowed_decisions = tuple(
            decision
            for decision in body.get("allowed_decisions", ("approve_once", "deny"))
            if decision in {"approve_once", "deny"}
        )
        if not allowed_decisions:
            allowed_decisions = ("approve_once", "deny")
        subscribed = self.storage.subscribed_devices(session_id)
        if not subscribed:
            return
        try:
            capabilities = self.storage.create_approval_capabilities(
                request_id=request_id,
                session_id=session_id,
                expires_at_ms=expires,
                device_ids=subscribed,
                allowed_decisions=allowed_decisions,
            )
        except (StorageConflict, StorageExpired):
            # A terminal/replayed request has no live authority to fan out.
            return

        if self.notifications is not None:
            try:
                # Freeze every encrypted preview before exposing its matching
                # in-app capability, but never wait on the Push network here.
                # Fixed-size background workers own all remote delivery.
                self.notifications.enqueue_approval_request(
                    session_id=session_id,
                    request_id=request_id,
                    title=str(body.get("title") or "Approval required"),
                    body=str(
                        body.get("description")
                        or body.get("target")
                        or "Review this approval in Hermes"
                    ),
                    expires_at_ms=expires,
                    destructive=bool(body.get("destructive", False)),
                    allowed_decisions=allowed_decisions,
                    capabilities=capabilities,
                )
            except Exception:
                # The encrypted in-app path remains authoritative even when
                # preview encryption/storage is unavailable.
                _log.warning("approval push enqueue failed", exc_info=True)

        for device_id in self.storage.subscribed_devices(session_id):
            device = self.storage.get_device(device_id)
            capability = capabilities.get(device_id)
            if device is None or capability is None:
                continue
            per_device = {
                "sid": session_id,
                "turn": frame.turn,
                "kind": FrameKind.APPROVAL_REQUEST,
                "body": {
                    **body,
                    "request_id": request_id,
                    "capability": capability,
                    "allowed_decisions": list(allowed_decisions),
                    "device_id": device_id,
                    "device_generation": device.kem_generation,
                },
            }
            self.router.publish_frames_to_device(
                device_id,
                [per_device],
                message_class=TransportClass.STATE,
            )

    async def _notify_terminal_frame(self, frame: Frame) -> None:
        """Send encrypted, presence-aware completion/error/update previews."""

        if self.notifications is None:
            return
        session_id = self.storage.origin_session_id(frame.sid)
        if not self._owns_session(frame.sid, session_id):
            return
        notification_class: NotificationClass | None = None
        title = ""
        preview_body = ""
        marks_turn = False

        if frame.kind == FrameKind.ITEM_COMPLETED:
            item_type = str(frame.body.get("type", ""))
            status = str(frame.body.get("status", ""))
            item_body = frame.body.get("body") or {}
            summary = str(frame.body.get("summary") or "").strip()
            text = (
                str(item_body.get("text") or "").strip()
                if isinstance(item_body, dict)
                else ""
            )
            if item_type == "error" or status == "failed":
                notification_class = NotificationClass.ERROR
                title = "Hermes needs attention"
                preview_body = summary or text or "The current Hermes task failed"
                marks_turn = True
            elif item_type == "agentMessage":
                notification_class = NotificationClass.UPDATE
                title = "Hermes reply ready"
                preview_body = summary or text or "Hermes finished responding"
                marks_turn = True
            elif item_type == "taskList":
                notification_class = NotificationClass.UPDATE
                title = "Hermes tasks updated"
                preview_body = summary or "Your Hermes task list changed"
            elif item_type in {"fileChange", "image", "browser"}:
                notification_class = NotificationClass.UPDATE
                title = "Hermes update ready"
                preview_body = summary or f"A {item_type} result is ready"
        elif frame.kind == FrameKind.TURN_COMPLETED:
            notification_class = NotificationClass.UPDATE
            title = "Hermes finished"
            preview_body = "Your Hermes task is complete"
            marks_turn = True

        if notification_class is None:
            return
        body_item_id = frame.body.get("item_id")
        event_anchor = str(frame.turn or "")
        if not event_anchor and isinstance(body_item_id, str):
            event_anchor = body_item_id
        if not event_anchor:
            event_anchor = hashlib.sha256(
                json.dumps(
                    {"kind": str(frame.kind), "body": frame.body},
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("utf-8")
            ).hexdigest()
        if marks_turn:
            terminal_base = f"terminal:{session_id}:{event_anchor}"
            error_key = f"{terminal_base}:error"
            if notification_class is NotificationClass.ERROR:
                dedupe_key = error_key
            else:
                # A durable error disposition dominates a later generic
                # turn-completed fallback.  An error that arrives after a
                # completion remains a distinct, audible notification.
                if self.storage.has_notification_dedupe(error_key):
                    return
                dedupe_key = f"{terminal_base}:completion"
        else:
            revision = frame.body.get("revision", "")
            dedupe_key = (
                f"update:{session_id}:{event_anchor}:{body_item_id}:{revision}:"
                f"{frame.kind}"
            )
        at = self.storage.current_time_ms()
        collapse = b64url_encode(
            hmac.new(
                self.identity.sign_private,
                b"hrp2-push-thread\x00" + session_id.encode("utf-8"),
                hashlib.sha256,
            ).digest()
        )
        notification_id = "nid_" + b64url_encode(
            hmac.new(
                self.identity.sign_private,
                b"hrp2-push-notification\x00" + dedupe_key.encode("utf-8"),
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
        for device_id in self.storage.subscribed_devices(session_id):
            device = self.storage.get_device(device_id)
            if device is None:
                continue
            preview = NotificationPreview(
                notification_id=notification_id,
                notification_class=notification_class,
                title=_bounded_preview(title, 200),
                body=_bounded_preview(preview_body, 1_200),
                thread_token=thread_token,
                expires_at_ms=at + DEFAULT_MAILBOX_TTL_MS,
            )
            try:
                self.notifications.enqueue_to_device(
                    device.device_id,
                    preview,
                    session_id=session_id,
                    collapse_id=collapse,
                    sound=notification_class is NotificationClass.ERROR,
                    dedupe_key=dedupe_key,
                )
            except Exception:
                _log.warning(
                    "terminal push enqueue failed for device %s",
                    device.device_id,
                    exc_info=True,
                )

    def _owns_session(self, presented_session_id: str, origin_session_id: str) -> bool:
        """Accept notification authority only for Relay-created Gateway sessions."""

        return self.gateway.owns(presented_session_id) or (
            origin_session_id in self.storage.owned_sessions()
        )

    async def _notification_pump(self) -> None:
        """Retry exact committed Push descriptors across outages and restarts."""

        assert self.notifications is not None
        while not self._closing:
            try:
                await self.notifications.flush_pending()
            except asyncio.CancelledError:
                raise
            except Exception:
                _log.warning("notification outbox retry failed", exc_info=True)
            await self.notifications.wait_for_work(NOTIFICATION_RETRY_INTERVAL_S)

    async def _pairing_pump(self) -> None:
        while not self._closing:
            self.storage.expire_pair_offers()
            for offer in self.storage.pair_offers(states=("pending", "claimed")):
                if not offer.hub_registered:
                    continue
                try:
                    claim = await self.pairing.claim_ready_offer(offer.offer_id)
                    if claim is None:
                        continue
                    if claim.offer.auto_approve:
                        await self.pairing.accept_claim(claim)
                    elif claim.offer.offer_id not in self._shown_pair_claims:
                        self._shown_pair_claims.add(claim.offer.offer_id)
                        _log.warning(
                            "pairing claim %s awaits operator confirmation; code %s",
                            claim.offer.offer_id,
                            claim.verification_code,
                        )
                except asyncio.CancelledError:
                    raise
                except Exception:
                    _log.warning("pairing offer processing failed", exc_info=True)
            await asyncio.sleep(1.0)

    def maintain_relay_keys(self) -> bool:
        """Retire expired keys and atomically rotate when either limit is due."""

        self.storage.retire_relay_kem_keys()
        if not self.storage.relay_rotation_due(
            max_age_ms=KEY_ROTATION_MAX_AGE_MS,
            max_messages=KEY_ROTATION_MAX_MESSAGES,
        ):
            return False
        # Every key-rotate body advances by exactly one generation.  A second
        # global rotation while any active device still awaits the first
        # authenticated inner receipt would make that peer skip a generation;
        # Hub acceptance/order cannot substitute for this receipt gate.
        if self.storage.relay_rotation_awaiting_device_receipts():
            return False

        old_identity = self.identity
        pair = generate_x25519_key_pair()
        generation = old_identity.kem_generation + 1
        at = self.storage.current_time_ms()
        notice_expires = at + DEFAULT_MAILBOX_TTL_MS
        previous_not_after = notice_expires + KEY_ROTATION_GRACE_MS
        protector = self.storage.credential_protector
        if protector is None:
            raise RuntimeError("Relay credential protector is unavailable")
        try:
            wrapped = protector.protect(
                f"{old_identity.relay_instance_id}:relay-kem:{generation}",
                pair.private_key,
            )
        except CredentialProtectionError:
            raise
        except Exception as exc:
            raise CredentialProtectionError(
                "Agent KEM rotation credential creation failed"
            ) from exc

        def notice(device):
            return self.router._seal(
                device,
                kind=SecureMessageKind.KEY_ROTATE,
                body={
                    "purpose": "kem",
                    "generation": generation,
                    "public_key": b64url_encode(pair.public_key),
                    "previous_not_after_ms": previous_not_after,
                },
                message_class=TransportClass.CONTROL,
                expires_at_ms=notice_expires,
            ).to_dict()

        try:
            _record, notices = self.storage.rotate_relay_kem_with_notices(
                new_generation=generation,
                new_private_key=wrapped,
                new_public_key=pair.public_key,
                previous_not_after_ms=previous_not_after,
                notice_expires_at_ms=notice_expires,
                envelope_factory=notice,
            )
        except Exception:
            try:
                protector.delete(wrapped)
            except Exception:
                pass
            raise

        rotated = RelayIdentity(
            relay_instance_id=old_identity.relay_instance_id,
            relay_epoch=old_identity.relay_epoch,
            kem_generation=generation,
            kem_private=pair.private_key,
            kem_public=pair.public_key,
            sign_private=old_identity.sign_private,
            sign_public=old_identity.sign_public,
            protection_mode=getattr(protector, "mode", old_identity.protection_mode),
        )
        self.identity = rotated
        self.router.identity = rotated
        self.pairing.identity = rotated
        if self.notifications is not None:
            self.notifications.identity = rotated
        if self._running:
            for record in notices:
                sender = self.router._sender(record.device_id)
                sender.start()
                sender.offer(record.message_id)
        return True

    async def prepare_startup_maintenance(self) -> None:
        """Run safe local phases, then always reconcile remote revocations."""

        # Expiry is itself a durable fail-closed transition.  Queue its remote
        # cleanup before the first reconciliation rather than waiting for the
        # one-second pairing pump after startup.
        self.storage.expire_pair_offers()
        try:
            self.maintain_relay_keys()
        except CredentialProtectionError:
            # Retirement/quarantine phases are already durable and retiring
            # keys are unavailable to send/receive paths.  Keep healthy-device
            # service and remote revocation alive; the key pump retries erasure.
            _log.warning(
                "Relay key cleanup remains pending at startup; retrying in pump",
                exc_info=True,
            )
        await self.reconcile_remote_revocations()

    async def _key_maintenance_pump(self) -> None:
        while not self._closing:
            try:
                self.maintain_relay_keys()
            except asyncio.CancelledError:
                raise
            except Exception:
                # Retirement is phase-persisted before external credential
                # deletion.  A transient backend failure must be retried by
                # this long-lived pump rather than silently disabling all
                # future key maintenance.
                _log.warning("Relay key maintenance failed; retrying", exc_info=True)
            if self._closing:
                break
            await asyncio.sleep(KEY_MAINTENANCE_INTERVAL_S)

    async def reconcile_remote_revocations(self) -> int:
        """Retry every quarantined Hub/Push revocation independently."""

        confirmed = 0
        for record in self.storage.pending_hub_device_revocations():
            try:
                result = await self.hub.delete_route(record.route_id)
                if self.storage.confirm_hub_device_revocation(
                    record.device_id,
                    route_id=result["route_id"],
                    grant_ids=result["grant_ids"],
                ):
                    confirmed += 1
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.storage.mark_hub_device_revocation_failed(
                    record.device_id, type(exc).__name__
                )
                _log.warning(
                    "quarantined Hub route revocation remains pending for %s",
                    record.device_id,
                    exc_info=True,
                )

        if self.push is not None:
            # An exchange response may have been lost after the Push Gateway
            # created a binding.  Revoke by its existing exchange secrets;
            # never recover or persist the send capability on a terminal path.
            for exchange in self.storage.pending_push_exchange_revocations():
                try:
                    await self.push.revoke_binding_exchange(
                        exchange.bind_token,
                        exchange_id=exchange.exchange_id,
                    )
                    if self.storage.confirm_push_exchange_remote_revocation(
                        exchange.device_id,
                        exchange_id=exchange.exchange_id,
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
                    _log.warning(
                        "quarantined Push exchange revocation remains pending for %s",
                        exchange.device_id,
                        exc_info=True,
                    )

            for record in self.storage.pending_push_binding_revocations():
                try:
                    capability = self.storage.push_binding_revocation_capability(
                        record.binding_id
                    )
                    await self.push.revoke_binding(
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
                        record.binding_id, type(exc).__name__
                    )
                    _log.warning(
                        "quarantined Push binding revocation remains pending for %s",
                        record.device_id,
                        exc_info=True,
                    )

        self.storage.finish_confirmed_remote_credential_cleanup()
        return confirmed

    async def _remote_revocation_pump(self) -> None:
        while not self._closing:
            try:
                await self.reconcile_remote_revocations()
            except asyncio.CancelledError:
                raise
            except Exception:
                _log.warning(
                    "remote quarantine reconciliation failed; retrying",
                    exc_info=True,
                )
            if self._closing:
                break
            await asyncio.sleep(KEY_MAINTENANCE_INTERVAL_S)

    def status(self) -> dict[str, Any]:
        return {
            "protocol": 2,
            "relay_instance_id": self.identity.relay_instance_id,
            "relay_route": self.relay_route,
            "protection_mode": self.identity.protection_mode,
            "devices": [
                {
                    "device_id": device.device_id,
                    "name": device.name,
                    "status": device.status,
                    "key_generation": device.kem_generation,
                    "re_pair_required": device.re_pair_required,
                    "status_reason": device.status_reason,
                    "hub_revocation_state": device.hub_revocation_state,
                    "hub_revocation_attempts": device.hub_revocation_attempts,
                    "hub_revocation_last_error": device.hub_revocation_last_error,
                }
                for device in self.storage.devices()
            ],
            "senders": [
                {
                    "device_id": status.device_id,
                    "running": status.running,
                    "wake_queue_size": status.wake_queue_size,
                    "last_error_code": status.last_error_code,
                }
                for status in self.router.status()
            ],
            "re_pair_credential_cleanup_pending": (
                self.storage.re_pair_credential_cleanup_pending()
            ),
            "re_pair_hub_revocation_pending": (
                self.storage.re_pair_hub_revocation_pending()
            ),
            "re_pair_push_revocations": self.storage.re_pair_push_revocation_status(),
            "closing": self._closing,
        }

    async def close(self) -> None:
        if self._closing and not self._tasks:
            return
        self._closing = True
        self._running = False
        await self.gateway.close()
        await self.hub.close()
        if self.push is not None:
            await self.push.close()
        await self.router.close()
        for task in self._tasks.values():
            task.cancel()
        if self._tasks:
            await asyncio.gather(*self._tasks.values(), return_exceptions=True)
        self._tasks = {}
        self.storage.close()


def _bounded_preview(value: str, maximum: int) -> str:
    text = value.strip() or "Hermes update"
    raw = text.encode("utf-8")
    if len(raw) <= maximum:
        return text
    return raw[:maximum].decode("utf-8", errors="ignore") or "Hermes update"


def read_protected_token_file(path: Path, *, label: str) -> str:
    """Read a non-empty secret file after enforcing owner-only POSIX mode."""

    token_path = Path(path).expanduser()
    try:
        value = read_secure_text_file(token_path, owner_only=True).strip()
    except (OSError, PermissionError, ValueError) as exc:
        raise PermissionError(f"{label} file cannot be read") from exc
    if not value:
        raise ValueError(f"{label} file is empty")
    return value


__all__ = [
    "FRAME_BATCH_MAX_BYTES",
    "KEY_MAINTENANCE_INTERVAL_S",
    "KEY_ROTATION_GRACE_MS",
    "KEY_ROTATION_MAX_AGE_MS",
    "KEY_ROTATION_MAX_MESSAGES",
    "V2RelayApp",
    "V2RelayConfig",
    "frame_batch_plaintext_size",
    "read_protected_token_file",
]
