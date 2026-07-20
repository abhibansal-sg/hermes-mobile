"""Scenario (h) — B14 live push path: register over relay -> notifier -> APNs.

QA-1 B14: the phone received ZERO notifications in relay mode. Two breaks,
both exercised here end-to-end:

1. **Token registration.** In relay mode the phone's APNs token was only ever
   POSTed to gateway-direct REST — unreachable off-LAN, and a different
   HERMES_HOME than the relay reads even on-LAN. The fix adds
   ``push.register``/``push.unregister`` upstream RPCs the relay answers
   LOCALLY, writing the registry its Notifier reads. Part 1 drives this over
   a REAL phone WS against the REAL relay subprocess and asserts the token
   lands in the subprocess's ``push_tokens.json``.

2. **Notifier arming.** The launchd service carried no APNs env, so
   ``push_engine.is_armed()`` was False and every notify no-op'd (the
   mock-APNs scenario (g) never hit ``is_armed`` because it injects a
   FakePush). Part 2 runs the REAL push_engine ARMED (generated throwaway
   ES256 key, tmp HERMES_HOME) with only the HTTP/2 socket mocked at the
   module's own ``_send_one`` seam: a token registered through the REAL
   ``DownstreamServer`` RPC path receives a genuine signed-JWT APNs send
   attempt when a backgrounded turn completes.

Hermetic by default (mock APNs transport seam, zero network). Opt-in
``E2E_APNS_LIVE_ATTEMPT=1`` + real creds in env performs one REAL APNs send
attempt (part 3) and records the status — the A8 evidence target when the
owner has placed the .p8 + Key/Team IDs.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Any

import pytest

_BRANCH_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_BRANCH_ROOT / "relay"))
sys.path.insert(0, str(Path(__file__).resolve().parent / "mock_gateway"))

from hermes_relay import plugin_bridge  # noqa: E402
from hermes_relay.bus import EventBus  # noqa: E402
from hermes_relay.downstream import (  # noqa: E402
    DownstreamConfig,
    DownstreamServer,
    PhoneConnection,
    build_ring,
)
from hermes_relay.notifier import Notifier, NotifierConfig  # noqa: E402
from hermes_relay.reframer import Reframer  # noqa: E402
from hermes_relay.session_state import SessionStore  # noqa: E402
from hermes_relay.types import GatewayEvent, UpstreamRequest  # noqa: E402

pytestmark = pytest.mark.asyncio

# A 64-hex APNs-shaped device token.
_DEVICE_TOKEN = "abc123def456abc123def456abc123def456abc123def456abc123def456abc1"


# ---------------------------------------------------------------------------
# Part 1 — REAL wire: phone -> relay subprocess -> relay-side registry.
# ---------------------------------------------------------------------------


async def test_push_register_over_relay_socket_lands_in_relay_registry(
    relay_subprocess, phone_factory, request, evidence, tmp_path
):
    """The token registered over the relay WS is in the RELAY process's own
    push_tokens.json. This is the 'does the token ever reach the notifier's
    registry' answer: YES, over the relay — no gateway REST, no shared-home
    coincidence.

    The relay subprocess inherits the per-test HERMES_HOME pinned by the
    autouse hermetic fixture (tests/conftest.py) — the same env knob the QA-1
    plist fix renders into the launchd service — so the registry lands at
    ``$HERMES_HOME/push_tokens.json``: exactly the file the relay's Notifier
    reads via push_engine."""
    phone = await phone_factory()
    try:
        envelope = await phone.push_register(
            _DEVICE_TOKEN,
            env="production",
            events=["approval", "clarify", "turn_complete", "turn_error"],
        )
        assert "result" in envelope, f"push.register failed: {envelope}"
        assert envelope["result"] == {"registered": True}

        # The subprocess resolves its registry via HERMES_HOME (inherited from
        # the pytest env the autouse fixture pins to this test's tmp_path).
        hermes_home = Path(os.environ["HERMES_HOME"])
        registry = hermes_home / "push_tokens.json"
        assert registry.is_file(), (
            f"relay never wrote its push registry at {registry}"
        )
        entries = json.loads(registry.read_text(encoding="utf-8"))
        match = [e for e in entries if e.get("token") == _DEVICE_TOKEN]
        assert len(match) == 1, f"token not in relay registry: {entries}"
        assert match[0]["env"] == "production"
        assert match[0]["events"] == [
            "approval", "clarify", "turn_complete", "turn_error",
        ]

        # Unregister round-trips too (Settings opt-out path).
        envelope = await phone.push_unregister(_DEVICE_TOKEN)
        assert envelope.get("result") == {"unregistered": True}
        entries = json.loads(registry.read_text(encoding="utf-8"))
        assert all(e.get("token") != _DEVICE_TOKEN for e in entries)

        evidence("h-push-register-wire", {
            "registry": str(registry),
            "hermes_home": str(hermes_home),
            "registered": True,
            "token_tail": _DEVICE_TOKEN[-6:],
            "events": ["approval", "clarify", "turn_complete", "turn_error"],
        })
    finally:
        await phone.close()


async def test_push_register_rejects_malformed_token_over_wire(
    relay_subprocess, phone_factory
):
    """A malformed token gets a JSON-RPC error, never a silent drop."""
    phone = await phone_factory()
    try:
        envelope = await phone.push_register("zz-not-hex")
        assert "error" in envelope, f"expected error, got: {envelope}"
        assert "invalid device token" in envelope["error"]["message"]
    finally:
        await phone.close()


# ---------------------------------------------------------------------------
# Part 2 — hermetic full path: RPC register -> reframed turn -> ARMED
# push_engine -> APNs send attempt (transport seam mocked).
# ---------------------------------------------------------------------------


class _FakeWS:
    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send(self, msg: str) -> None:
        self.sent.append(msg)


class _OwningGateway:
    def owns(self, sid: str) -> bool:
        return True


def _write_throwaway_p8(path: Path) -> None:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    key = ec.generate_private_key(ec.SECP256R1())
    path.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )


async def test_registered_token_receives_armed_apns_attempt_on_backgrounded_turn(
    mock_gateway, tmp_path, monkeypatch, evidence
):
    pytest.importorskip("jwt", reason="APNs JWT requires PyJWT")
    pytest.importorskip("cryptography", reason="ES256 signing requires cryptography")
    pytest.importorskip("h2", reason="push_engine dials APNs over HTTP/2")

    # Isolated + ARMED relay push environment.
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    key_file = tmp_path / "apns-key.p8"
    _write_throwaway_p8(key_file)
    monkeypatch.setenv("HERMES_PUSH_ENABLED", "1")
    monkeypatch.setenv("HERMES_APNS_KEY_FILE", str(key_file))
    monkeypatch.setenv("HERMES_APNS_KEY_ID", "TESTKEY123")
    monkeypatch.setenv("HERMES_APNS_TEAM_ID", "TESTTEAM45")
    monkeypatch.setenv("HERMES_APNS_TOPIC", "ai.hermes.app")
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)

    push = plugin_bridge.import_push_engine()
    monkeypatch.setattr(push, "_cached_jwt", None, raising=False)
    monkeypatch.setattr(push, "_cached_jwt_at", 0.0, raising=False)
    for entry in push.registry_entries():
        push.unregister_token(entry["token"])

    # REAL DownstreamServer answers push.register exactly like the service.
    server = DownstreamServer(
        DownstreamConfig(), EventBus(), _OwningGateway(), SessionStore(),
        push_engine=push,
    )
    conn = PhoneConnection("phone-h", _FakeWS(), build_ring(DownstreamConfig()))
    reg = await server.handle_upstream(
        conn,
        UpstreamRequest(
            method="push.register",
            params={
                "token": _DEVICE_TOKEN, "platform": "ios", "env": "production",
                "events": ["turn_complete", "approval", "clarify"],
            },
            id=1,
        ),
    )
    assert reg == {"registered": True}
    assert _DEVICE_TOKEN in push.registered_tokens()

    # Mock the HTTP/2 socket at the module's own swappable seam; everything
    # above it (JWT mint, headers, recipient selection) is REAL.
    attempts: list[dict[str, Any]] = []

    def fake_send_one(conn_, *, device_token, headers, body):
        attempts.append(
            {"device_token": device_token, "headers": dict(headers),
             "payload": json.loads(body)}
        )
        return 200, ""

    monkeypatch.setattr(push, "_send_one", fake_send_one)

    # Drive a REAL mock-gateway turn through the REAL reframer into a REAL
    # Notifier wired to the REAL (armed) push_engine — phone BACKGROUNDED
    # (no foreground), so the §6 gate lets turn_complete through.
    notifier = Notifier(
        NotifierConfig(), EventBus(), _OwningGateway(),
        is_foregrounded=lambda sid: False, push_engine=push,
    )
    reframer = Reframer(EventBus(), SessionStore())

    from mock_gateway.server import create_scripted_session

    sid = await create_scripted_session(
        mock_gateway, script="simple", wait_timeout_s=0.3,
        text="Turn finishes while the phone is backgrounded.",
    )
    captured: list[dict[str, Any]] = []
    orig_broadcast = mock_gateway._broadcast

    async def tap(sid_: str, params: dict[str, Any]) -> None:
        ge = GatewayEvent(
            type=params.get("type", ""),
            session_id=sid_,
            payload=dict(params.get("payload") or {}),
        )
        for frame in reframer.reframe(ge):
            descriptor = notifier.observe(frame)
            if descriptor is not None:
                captured.append(descriptor)
        await asyncio.sleep(0)

    mock_gateway._broadcast = tap  # type: ignore[assignment]
    try:
        await mock_gateway._run_script(mock_gateway.sessions[sid])
    finally:
        mock_gateway._broadcast = orig_broadcast  # type: ignore[assignment]

    # The notifier fired turn_complete AND the armed push_engine attempted a
    # real APNs send to the token registered over the RPC path.
    assert [c["event_type"] for c in captured] == ["turn_complete"]
    assert len(attempts) == 1, f"expected one APNs attempt, got {attempts}"
    attempt = attempts[0]
    assert attempt["device_token"] == _DEVICE_TOKEN
    assert attempt["headers"]["apns-topic"] == "ai.hermes.app"
    assert attempt["headers"]["authorization"].startswith("bearer ")
    assert attempt["payload"]["hermes"]["session_id"] == sid
    assert attempt["payload"]["aps"]["alert"]["title"] == "Hermes finished"

    evidence("h-armed-apns-attempt", {
        "session_id": sid,
        "event_type": "turn_complete",
        "device_token_tail": _DEVICE_TOKEN[-6:],
        "apns_topic": attempt["headers"]["apns-topic"],
        "apns_push_type": attempt["headers"]["apns-push-type"],
        "jwt_minted": True,
        "transport": "mocked at push_engine._send_one (hermetic)",
        "alert_title": attempt["payload"]["aps"]["alert"]["title"],
    })


# ---------------------------------------------------------------------------
# Part 3 — OPT-IN one REAL APNs send attempt (A8 evidence target).
#
# Runs only with E2E_APNS_LIVE_ATTEMPT=1 and real creds in env
# (HERMES_APNS_KEY_FILE/_KEY_ID/_TEAM_ID). Requires a REAL device token
# registered for this build in E2E_APNS_DEVICE_TOKEN. Records the APNs HTTP
# status — the exact remaining-blocker evidence when creds are incomplete.
# ---------------------------------------------------------------------------


async def test_live_apns_send_attempt_opt_in(tmp_path, monkeypatch, evidence):
    if os.environ.get("E2E_APNS_LIVE_ATTEMPT", "0") != "1":
        pytest.skip("set E2E_APNS_LIVE_ATTEMPT=1 + real creds to run")
    pytest.importorskip("jwt")
    pytest.importorskip("cryptography")
    pytest.importorskip("h2")

    device_token = os.environ.get("E2E_APNS_DEVICE_TOKEN", "")
    if not device_token:
        pytest.skip("E2E_APNS_DEVICE_TOKEN (real device token) required")

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    push = plugin_bridge.import_push_engine()
    config = push.APNsConfig.from_env()
    if not config.is_armed():
        evidence("h-live-attempt-blocked", {
            "armed": False,
            "enabled": config.enabled,
            "key_file_set": bool(config.key_file),
            "key_file_exists": config.key_file_exists(),
            "key_id_set": bool(config.key_id),
            "team_id_set": bool(config.team_id),
            "owner_action": "place AuthKey_*.p8 at HERMES_APNS_KEY_FILE and set "
                            "HERMES_APNS_KEY_ID + HERMES_APNS_TEAM_ID",
        })
        pytest.fail(
            "APNs not armed — owner action: provide .p8 + Key ID + Team ID "
            "(see evidence h-live-attempt-blocked)"
        )

    push.register_token(device_token, env="production")
    accepted = push.notify(
        "turn_complete", "Hermes finished",
        "QA-1 B14 live push-path proof from the isolated relay harness.",
        {"session_id": "qa1-live-attempt"},
        category="HERMES_TURN", expiration=0,
    )
    evidence("h-live-attempt", {
        "armed": True,
        "accepted": accepted,
        "token_tail": device_token[-6:],
        "note": "accepted==1 -> APNs HTTP 200; 0 -> see relay/push_engine log "
                "for the APNs status (BadDeviceToken/400 means the path works "
                "end-to-end and the token is stale/wrong-env)",
    })
