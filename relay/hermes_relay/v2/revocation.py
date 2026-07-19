"""Loss-safe owner-authorized device revocation orchestration."""

from __future__ import annotations

import asyncio
from typing import Any

from .errors import NotFound
from .hub_client import HubClient
from .notification_sender import NotificationSender
from .storage import RelayStorage


class DeviceRevoker:
    def __init__(
        self,
        storage: RelayStorage,
        hub: HubClient,
        notifications: NotificationSender | None = None,
    ) -> None:
        self.storage = storage
        self.hub = hub
        self.notifications = notifications

    async def revoke(
        self,
        device_id: str,
        *,
        inbound_message_id: str | None = None,
        inbound_expires_at_ms: int | None = None,
    ) -> dict[str, Any]:
        device = self.storage.get_device(device_id, include_inactive=True)
        if device is None:
            raise NotFound()

        # The local tombstone is the security boundary.  Never leave a device
        # active merely because a Hub or Push response is unavailable/lost.
        self.storage.queue_device_revocation(
            device_id,
            inbound_message_id=inbound_message_id,
            inbound_expires_at_ms=inbound_expires_at_ms,
        )

        already_revoked = device.status == "revoked"
        errors: list[Exception] = []
        pending_hub = next(
            (
                record
                for record in self.storage.pending_hub_device_revocations()
                if record.device_id == device_id
            ),
            None,
        )
        if pending_hub is not None:
            try:
                result = await self.hub.delete_route(pending_hub.route_id)
                self.storage.confirm_hub_device_revocation(
                    device_id,
                    route_id=result["route_id"],
                    grant_ids=result["grant_ids"],
                )
                already_revoked = bool(result["already_revoked"])
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.storage.mark_hub_device_revocation_failed(
                    device_id, type(exc).__name__
                )
                errors.append(exc)

        if self.notifications is not None:
            try:
                await self.notifications.reconcile_device_revocation(device_id)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                errors.append(exc)

        if errors:
            raise errors[0]
        return {
            "device_id": device_id,
            "route_id": device.route,
            "status": "revoked",
            "already_revoked": already_revoked,
        }


__all__ = ["DeviceRevoker"]
