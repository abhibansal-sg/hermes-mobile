"""Shared client for the hermes-mobile opt-in push relay.

Adapted from Fetch's ``_relay.py`` for ABH-208 Slice B. The relay holds APNs
credentials and fans out to registered devices. This host stores only an
anonymous per-agent ``agent_id`` + ``agent_secret`` minted on first relay use.

Relay mode is deliberately opt-in: no hosted relay URL is compiled in. Set
``HERMES_MOBILE_RELAY_URL`` (or the same key in this Hermes home's ``.env``)
to route push delivery through the relay; unset means the existing direct APNs
path in ``push_engine.py`` remains authoritative.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx

log = logging.getLogger("hermes_mobile.relay")

# No hosted default: relay transport is self-hosted / explicitly configured.
DEFAULT_RELAY_URL: str | None = None

_DEDUPE_WINDOW_S = 10.0
RELAY_PUSH_KINDS = ("replies", "attention", "proactive")
_HERMES_TO_RELAY_KIND = {
    "approval": "attention",
    "clarify": "attention",
    "turn_complete": "replies",
}


def _hermes_home(hermes_home: Path | None = None) -> Path:
    if hermes_home is not None:
        return Path(hermes_home).expanduser()
    store_home = os.environ.get("HERMES_MOBILE_RELAY_STORE_HOME", "").strip()
    if store_home:
        return Path(os.path.expanduser(store_home))
    try:
        from hermes_cli.config import get_hermes_home

        return Path(get_hermes_home())
    except Exception:
        return Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes"))


def _parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return values
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        value = value.strip()
        if value[:1] in {"'", '"'}:
            quote = value[0]
            end = value.find(quote, 1)
            value = value[1:end] if end != -1 else value[1:]
        if key:
            values[key] = value
    return values


def _config_value(
    name: str, default: str | None = None, *, hermes_home: Path | None = None
) -> str | None:
    """Read a config value from the environment, falling back to a Hermes home's .env."""
    val = os.environ.get(name)
    if val:
        return val
    file_val = _parse_env_file(_hermes_home(hermes_home) / ".env").get(name)
    return file_val if file_val else default


class NeedsAttestation(Exception):
    """Relay requires an App Attest attestation to enroll this agent."""


class RelayConfigurationError(RuntimeError):
    """Raised when relay mode is used without ``HERMES_MOBILE_RELAY_URL``."""


@dataclass(frozen=True)
class RelayCredentials:
    relay_url: str
    agent_id: str
    agent_secret: str
    # App-tunnel pairing capability token (plaintext). Minted by the relay and
    # returned once at registration; the relay keeps only its hash, so this is
    # the agent's only copy. None for agents enrolled before pairing capture
    # existed — re-minted on demand via ``relay_pairing()``.
    pairing: str | None = None


def map_push_kind(kind: str) -> str:
    """Map Hermes direct-mode event kinds to the relay PushKind taxonomy."""
    return _HERMES_TO_RELAY_KIND.get(kind, "proactive")


def relay_url(hermes_home: Path | None = None) -> str | None:
    configured = _config_value(
        "HERMES_MOBILE_RELAY_URL", DEFAULT_RELAY_URL, hermes_home=hermes_home
    )
    if configured:
        return configured.rstrip("/")
    return None


def relay_url_configured(*, hermes_home: Path | None = None) -> bool:
    return relay_url(hermes_home) is not None


class RelayClient:
    """Talks the push relay's ``/v1/*`` contract with per-agent auth."""

    def __init__(
        self,
        *,
        relay_url: str,
        credentials_path: Path,
        registration_token: str | None = None,
    ) -> None:
        self.relay_url = relay_url.rstrip("/")
        self.credentials_path = Path(credentials_path)
        self.registration_token = registration_token

    async def get_attest_challenge(self) -> str:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(f"{self.relay_url}/v1/attest/challenge")
        response.raise_for_status()
        return str(response.json()["challenge"])

    async def register_device(
        self,
        *,
        token: str,
        platform: str,
        environment: str,
        bundle_id: str,
        preferences: dict,
        attestation: dict | None = None,
    ) -> None:
        await self._post(
            "/v1/devices/register",
            {
                "token": token,
                "platform": platform,
                "environment": environment,
                "bundle_id": bundle_id,
                "preferences": preferences,
            },
            authenticated=True,
            attestation=attestation,
        )

    async def unregister_device(self, *, token: str) -> None:
        await self._post("/v1/devices/unregister", {"token": token}, authenticated=True)

    async def send_event(
        self,
        *,
        kind: str,
        session_id: str | None,
        title: str,
        body: str,
        source: str | None = None,
    ) -> None:
        await self._post(
            "/v1/push/events",
            {
                "type": kind,
                "session_id": session_id,
                "title": title,
                "body": body,
                "source": source,
            },
            authenticated=True,
        )

    async def _post(
        self,
        path: str,
        json_body: dict,
        *,
        authenticated: bool,
        attestation: dict | None = None,
    ) -> None:
        response: httpx.Response | None = None
        attempts = 2 if authenticated else 1
        for attempt in range(attempts):
            headers: dict[str, str] = {}
            if authenticated:
                creds = await self._credentials(attestation=attestation)
                headers["X-Hermes-Agent-Id"] = creds.agent_id
                headers["Authorization"] = f"Bearer {creds.agent_secret}"
            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.post(
                    f"{self.relay_url}{path}", headers=headers, json=json_body
                )
            # A 401 means our cached credentials were revoked/rotated server-side;
            # drop them and re-mint once.
            if authenticated and response.status_code == 401 and attempt == 0:
                self._clear_credentials()
                continue
            break
        if response is None:
            # The loop body always assigns at least once, but assert would be
            # stripped under `python -O`; guard explicitly so a future refactor
            # that skips the loop fails loudly instead of crashing on None.
            raise RuntimeError("relay request produced no response")
        response.raise_for_status()

    async def _credentials(self, attestation: dict | None = None) -> RelayCredentials:
        existing = self._read_credentials()
        if existing is not None:
            return existing
        headers: dict[str, str] = {}
        if self.registration_token:
            headers["X-Hermes-Relay-Registration-Token"] = self.registration_token
        body: dict[str, Any] = {"app": "hermes-ios"}
        if attestation:
            try:
                body.update(
                    {
                        "attestation": attestation["attestation"],
                        "key_id": attestation["key_id"],
                        "challenge": attestation["challenge"],
                    }
                )
            except KeyError as exc:
                raise ValueError(f"attestation dict missing key: {exc}") from exc
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(
                f"{self.relay_url}/v1/agents/register", headers=headers, json=body
            )
        # Relay returns 400 with detail "attestation required" when App Attest
        # enrollment is required but no attestation was supplied. Prefer the
        # structured detail field; fall back to response text. Match exactly
        # "attestation required" so other 400s don't false-trigger.
        if response.status_code == 400:
            detail = ""
            try:
                detail = str(response.json().get("detail", ""))
            except Exception:
                detail = response.text or ""
            if "attestation required" in detail.lower():
                raise NeedsAttestation("relay requires attestation to enroll")
        response.raise_for_status()
        data = response.json()
        pairing = data.get("pairing_secret")
        creds = RelayCredentials(
            relay_url=self.relay_url,
            agent_id=str(data["agent_id"]),
            agent_secret=str(data["agent_secret"]),
            pairing=str(pairing) if pairing else None,
        )
        self._write_credentials(creds)
        # Re-read so two processes that mint concurrently converge on whichever
        # identity won the atomic file write.
        return self._read_credentials() or creds

    async def relay_pairing(self) -> tuple[str, str, str]:
        """Return ``(relay_url, agent_id, pairing)`` for a relay setup link."""
        creds = await self._credentials()
        pairing = await self._mint_pairing(creds)
        return self.relay_url, creds.agent_id, pairing

    async def tunnel_status(self) -> dict:
        """Return the relay's view of this agent's tunnel readiness."""
        creds = await self._credentials()
        headers = {
            "X-Hermes-Agent-Id": creds.agent_id,
            "Authorization": f"Bearer {creds.agent_secret}",
        }
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(
                f"{self.relay_url}/v1/agents/tunnel/status", headers=headers
            )
        if response.status_code == 404:
            return {"ok": False, "reason": "status_unavailable", "status_code": 404}
        if response.status_code in {200, 503}:
            try:
                return response.json()
            except ValueError:
                return {"ok": False, "reason": "invalid_status_response"}
        response.raise_for_status()
        return response.json()

    async def wait_for_tunnel_online(
        self, *, timeout_s: float = 20.0, interval_s: float = 0.5
    ) -> dict:
        """Poll until the relay sees this agent's tunnel uplink or time expires."""
        deadline = time.monotonic() + max(0.0, timeout_s)
        last: dict = {"ok": False, "reason": "not_checked"}
        while True:
            try:
                last = await self.tunnel_status()
            except Exception as exc:
                last = {"ok": False, "reason": type(exc).__name__}
            if bool(last.get("ok") or last.get("agent_online")):
                return last
            if time.monotonic() >= deadline:
                return last
            await asyncio.sleep(max(0.1, interval_s))

    async def _mint_pairing(self, creds: RelayCredentials) -> str:
        """Rotate + fetch a fresh pairing token for an already-enrolled agent."""
        headers = {
            "X-Hermes-Agent-Id": creds.agent_id,
            "Authorization": f"Bearer {creds.agent_secret}",
        }
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(
                f"{self.relay_url}/v1/agents/pairing", headers=headers, json={}
            )
        response.raise_for_status()
        pairing = str(response.json()["pairing_secret"])
        # Persist alongside the existing identity so the file stays a valid
        # pairing record (drives setup / tunnel autostart in later slices).
        self._write_credentials(
            RelayCredentials(
                relay_url=creds.relay_url,
                agent_id=creds.agent_id,
                agent_secret=creds.agent_secret,
                pairing=pairing,
            )
        )
        return pairing

    def _read_credentials(self) -> RelayCredentials | None:
        try:
            data = json.loads(self.credentials_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        if data.get("relay_url") != self.relay_url:
            return None
        agent_id = str(data.get("agent_id") or "")
        agent_secret = str(data.get("agent_secret") or "")
        if not agent_id or not agent_secret:
            return None
        pairing = data.get("pairing")
        return RelayCredentials(
            relay_url=self.relay_url,
            agent_id=agent_id,
            agent_secret=agent_secret,
            pairing=str(pairing) if pairing else None,
        )

    def _write_credentials(self, creds: RelayCredentials) -> None:
        self.credentials_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.credentials_path.with_suffix(".tmp")
        payload = {
            "relay_url": creds.relay_url,
            "agent_id": creds.agent_id,
            "agent_secret": creds.agent_secret,
        }
        if creds.pairing:
            payload["pairing"] = creds.pairing
        tmp.write_text(
            json.dumps(payload, indent=2, sort_keys=True),
            encoding="utf-8",
        )
        try:
            os.chmod(tmp, 0o600)
        except OSError:
            pass
        os.replace(tmp, self.credentials_path)

    def _clear_credentials(self) -> None:
        try:
            self.credentials_path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            log.debug("Could not remove stale Hermes relay credentials", exc_info=True)


_client_singletons: dict[Path, RelayClient] = {}
_client_lock = threading.RLock()


def relay_client(*, hermes_home: Path | None = None) -> RelayClient:
    home = _hermes_home(hermes_home)
    with _client_lock:
        client = _client_singletons.get(home)
        configured_url = relay_url(home)
        if not configured_url:
            raise RelayConfigurationError("HERMES_MOBILE_RELAY_URL is not configured")
        if client is None or client.relay_url != configured_url:
            token = _config_value(
                "HERMES_MOBILE_RELAY_REGISTRATION_TOKEN", hermes_home=home
            )
            client = RelayClient(
                relay_url=configured_url,
                credentials_path=home / "push" / "relay.json",
                registration_token=token,
            )
            _client_singletons[home] = client
        return client


_recent: dict[str, float] = {}
_recent_lock = threading.Lock()


def _is_duplicate(key: str) -> bool:
    now = time.time()
    with _recent_lock:
        last = _recent.get(key)
        _recent[key] = now
        if len(_recent) > 512:  # opportunistic cleanup
            for k, t in list(_recent.items()):
                if now - t > _DEDUPE_WINDOW_S:
                    _recent.pop(k, None)
    return last is not None and (now - last) < _DEDUPE_WINDOW_S


def send_event_background(
    *,
    kind: str,
    session_id: str | None,
    title: str,
    body: str,
    source: str | None = None,
    hermes_home: Path | None = None,
) -> None:
    """Fire-and-forget a push event to the relay. Never blocks the caller."""
    relay_kind = map_push_kind(kind) if kind not in RELAY_PUSH_KINDS else kind
    if _is_duplicate(f"{relay_kind}:{session_id or ''}:{(body or '')[:80]}"):
        return
    threading.Thread(
        target=_send_sync,
        args=(relay_kind, session_id, title, body, source, hermes_home),
        daemon=True,
        name=f"hermes-mobile-push-{relay_kind}",
    ).start()


def send_live_activity_background(
    *,
    session_id: str,
    content_state: dict[str, Any],
    end: bool = False,
    hermes_home: Path | None = None,
) -> None:
    """Relay-mode fallback for ActivityKit updates.

    The relay contract is alert-event based, not a direct ActivityKit remote
    update API. Keep the branch non-blocking and map user-visible attention
    states into the relay's category vocabulary so relay-mode hosts still emit a
    best-effort phone wake-up without touching the direct APNs implementation.
    """
    phase = str(content_state.get("phase") or "update")
    if end:
        relay_kind = "replies"
        title = "Hermes finished"
        body = "Turn finished"
    elif bool(content_state.get("needsApproval")) or phase == "waiting":
        relay_kind = "attention"
        title = "Hermes needs your attention"
        body = "Review this request in Hermes"
    else:
        relay_kind = "proactive"
        title = "Hermes update"
        body = f"Current phase: {phase}"
    send_event_background(
        kind=relay_kind,
        session_id=session_id,
        title=title,
        body=body,
        source="live_activity",
        hermes_home=hermes_home,
    )


def _send_sync(
    kind: str,
    session_id: str | None,
    title: str,
    body: str,
    source: str | None,
    hermes_home: Path | None,
) -> None:
    try:
        asyncio.run(
            relay_client(hermes_home=hermes_home).send_event(
                kind=kind,
                session_id=session_id,
                title=title,
                body=body,
                source=source,
            )
        )
    except Exception:
        log.debug("Hermes relay push event delivery failed", exc_info=True)
