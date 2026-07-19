"""Loss-safe Agent route bootstrap for first-device pairing."""

from __future__ import annotations

from .errors import Expired, Revoked
from .hub_client import HubClient
from .identity import RelayIdentity
from .storage import AgentEnrollmentRecord, RelayStorage


class AgentEnrollmentManager:
    """Create at most one live provisional route for an Agent identity.

    The enrollment identifier and public key are committed locally before the
    first HTTP attempt.  An unknown transport outcome always retries those
    exact bytes; only an explicit Hub expiry/revocation (or a locally known
    provisional TTL expiry) permits a fresh identifier.
    """

    def __init__(
        self,
        storage: RelayStorage,
        identity: RelayIdentity,
        hub_client: HubClient,
    ) -> None:
        self.storage = storage
        self.identity = identity
        self.hub_client = hub_client

    async def ensure_provisional(self) -> AgentEnrollmentRecord:
        record = self.storage.prepare_agent_enrollment(self.identity.sign_public)
        if record.state == "active":
            return record
        if (
            record.state == "provisional"
            and record.expires_at_ms is not None
            and record.expires_at_ms > self.storage.current_time_ms()
        ):
            return record
        if record.state == "provisional":
            self.storage.mark_agent_enrollment(record.enrollment_id, state="expired")
            record = self.storage.prepare_agent_enrollment(self.identity.sign_public)

        for _attempt in range(2):
            try:
                result = await self.hub_client.enroll_provisional_agent(
                    enrollment_id=record.enrollment_id,
                    auth_public_key=record.auth_public_key,
                )
            except Expired:
                self.storage.mark_agent_enrollment(
                    record.enrollment_id, state="expired"
                )
                record = self.storage.prepare_agent_enrollment(
                    self.identity.sign_public
                )
                continue
            except Revoked:
                self.storage.mark_agent_enrollment(
                    record.enrollment_id, state="revoked"
                )
                record = self.storage.prepare_agent_enrollment(
                    self.identity.sign_public
                )
                continue
            return self.storage.record_provisional_agent_enrollment(
                enrollment_id=record.enrollment_id,
                auth_public_key=record.auth_public_key,
                route_id=result["route_id"],
                expires_at_ms=result["expires_at_ms"],
            )
        # A newly-created enrollment cannot already be terminal unless the
        # service rejected it deterministically; preserve the last exception's
        # typed semantics by making one final exact attempt.
        result = await self.hub_client.enroll_provisional_agent(
            enrollment_id=record.enrollment_id,
            auth_public_key=record.auth_public_key,
        )
        return self.storage.record_provisional_agent_enrollment(
            enrollment_id=record.enrollment_id,
            auth_public_key=record.auth_public_key,
            route_id=result["route_id"],
            expires_at_ms=result["expires_at_ms"],
        )

    async def activate_with_operator_token(
        self, record: AgentEnrollmentRecord, operator_enrollment_token: str
    ) -> AgentEnrollmentRecord:
        """Activate a self-hosted Agent route using file-loaded authority.

        The token is never persisted here.  If the Hub commits and its response
        is lost, the local row remains provisional and startup retries the
        exact route/body/header with the same operator token file.
        """

        if record.state == "active":
            return record
        if record.state != "provisional" or record.route_id is None:
            raise RuntimeError("Agent route is not ready for activation")
        token = operator_enrollment_token.strip()
        if not token:
            raise ValueError("operator enrollment token is empty")
        await self.hub_client.activate_agent_route(operator_enrollment_token=token)
        self.storage.mark_agent_route_active(record.route_id)
        active = self.storage.agent_enrollment(record.enrollment_id)
        if active is None or active.state != "active":
            raise RuntimeError("Agent route activation was not persisted")
        return active


__all__ = ["AgentEnrollmentManager"]
