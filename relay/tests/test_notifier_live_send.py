"""QA-1 B14 — the ARMED live-send path: Notifier -> REAL push_engine -> APNs.

The mock-APNs unit tests (``test_notifier.py``) inject a FakePush and never
exercise ``push_engine.is_armed()`` / the JWT+HTTP2 sender — which is exactly
why the live service could pass every test and still send ZERO pushes (the
launchd plist carried no APNs env, so ``is_armed()`` was False and every
``notify`` no-op'd). These tests pin the OTHER half of the contract:

* UNARMED (no env)  -> ``notify`` is a documented no-op returning 0;
* ARMED (env + key) -> the Notifier's fire reaches the APNs transport seam
  (``push_engine._send_one``) with the REGISTERED device token, a signed ES256
  provider JWT, the topic header, and the exact alert payload — i.e. once the
  service env is present (install-service.sh fix), a push is genuinely
  attempted. The HTTP/2 socket itself is mocked at ``_send_one`` (the module's
  own "transport swappable in tests" seam): no network, real crypto.

Requires PyJWT + cryptography + h2 (the relay's declared push deps); skipped
in venvs without them. Hermetic: tmp HERMES_HOME, generated throwaway ES256
key, zero network.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from hermes_relay.bus import EventBus
from hermes_relay.notifier import Notifier, NotifierConfig
from hermes_relay.types import Frame, FrameKind, Item, ItemStatus, ItemType

pytest.importorskip("jwt", reason="APNs provider JWT requires PyJWT")
pytest.importorskip("cryptography", reason="APNs ES256 signing requires cryptography")
pytest.importorskip("h2", reason="push_engine dials APNs over HTTP/2 (httpx[h2])")

from hermes_relay import plugin_bridge  # noqa: E402


# 64-hex APNs-shaped device token.
_DEVICE_TOKEN = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"


class _FakeGateway:
    def __init__(self, owned):
        self._owned = set(owned)

    def owns(self, sid: str) -> bool:
        return sid in self._owned


def _agent_completed(sid="s1", turn="t1", text="Paris is the capital."):
    return Frame.with_item(
        sid,
        FrameKind.ITEM_COMPLETED,
        Item("m1", ItemType.AGENT_MESSAGE, ItemStatus.COMPLETED, 0, body={"text": text}),
        turn,
    )


@pytest.fixture
def push_engine_isolated(tmp_path, monkeypatch):
    """REAL push_engine with an isolated registry + a generated throwaway key."""
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    push = plugin_bridge.import_push_engine()
    # Any cached provider JWT from another test would bypass the key file read;
    # force a fresh mint against THIS test's key.
    monkeypatch.setattr(push, "_cached_jwt", None, raising=False)
    monkeypatch.setattr(push, "_cached_jwt_at", 0.0, raising=False)
    for entry in push.registry_entries():
        push.unregister_token(entry["token"])
    return push


def _write_throwaway_p8(path: Path) -> None:
    """Generate a real ES256 (P-256) key — APNs auth is JWT/ES256, so the JWT
    mint is genuine crypto, not a stub."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    path.write_bytes(pem)


def test_unarmed_notify_is_a_noop(push_engine_isolated, monkeypatch):
    """No env -> is_armed() False -> notify returns 0 without any send attempt
    (the exact hole the QA-1 service fix closes at the config layer)."""
    push = push_engine_isolated
    monkeypatch.delenv("HERMES_PUSH_ENABLED", raising=False)
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    push.register_token(_DEVICE_TOKEN, env="production")
    calls = []
    monkeypatch.setattr(
        push, "_send_one", lambda *a, **k: calls.append((a, k)) or (200, "")
    )
    assert push.notify("turn_complete", "Hermes finished", "done", {}) == 0
    assert calls == []


def test_armed_notifier_attempts_apns_send_to_registered_token(
    push_engine_isolated, tmp_path, monkeypatch
):
    """ARMED env + registered token: a turn_complete frame fires a genuine APNs
    send attempt — signed JWT, topic header, the registered device token, the
    alert payload — at the transport seam (no network)."""
    push = push_engine_isolated
    key_file = tmp_path / "apns-key.p8"
    _write_throwaway_p8(key_file)
    monkeypatch.setenv("HERMES_PUSH_ENABLED", "1")
    monkeypatch.setenv("HERMES_APNS_KEY_FILE", str(key_file))
    monkeypatch.setenv("HERMES_APNS_KEY_ID", "TESTKEY123")
    monkeypatch.setenv("HERMES_APNS_TEAM_ID", "TESTTEAM45")
    monkeypatch.setenv("HERMES_APNS_TOPIC", "ai.hermes.app")
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)

    push.register_token(_DEVICE_TOKEN, env="production")

    sent: list[dict] = []

    def fake_send_one(conn, *, device_token, headers, body):
        sent.append({"device_token": device_token, "headers": headers, "body": body})
        return 200, ""

    monkeypatch.setattr(push, "_send_one", fake_send_one)

    notifier = Notifier(
        NotifierConfig(),
        EventBus(),
        _FakeGateway(owned={"s1"}),
        is_foregrounded=lambda sid: False,  # phone backgrounded
        push_engine=push,
    )
    descriptor = notifier.observe(_agent_completed())
    assert descriptor is not None
    assert descriptor["event_type"] == "turn_complete"

    # Exactly one APNs send attempt, to the registered token.
    assert len(sent) == 1
    attempt = sent[0]
    assert attempt["device_token"] == _DEVICE_TOKEN
    headers = attempt["headers"]
    assert headers["apns-topic"] == "ai.hermes.app"
    assert headers["apns-push-type"] == "alert"
    assert headers["authorization"].startswith("bearer ")
    # The provider JWT is a REAL ES256 token minted from the .p8 key.
    import jwt as pyjwt

    claims = pyjwt.decode(
        headers["authorization"].removeprefix("bearer "),
        options={"verify_signature": False},
    )
    assert claims["iss"] == "TESTTEAM45"
    # Payload round-trips the turn identity for the iOS action handler.
    payload = json.loads(attempt["body"])
    assert payload["aps"]["alert"]["title"] == "Hermes finished"
    assert payload["hermes"]["event_type"] == "turn_complete"
    assert payload["hermes"]["session_id"] == "s1"
    assert notifier.metrics.fired == 1


def test_armed_but_foregrounded_turn_stays_suppressed(
    push_engine_isolated, tmp_path, monkeypatch
):
    """Arming changes NOTHING about the §6 gate: a foregrounded session's
    turn_complete is still suppressed (no send attempt), while a blocking gate
    (approval) still bypasses it."""
    push = push_engine_isolated
    key_file = tmp_path / "apns-key.p8"
    _write_throwaway_p8(key_file)
    monkeypatch.setenv("HERMES_PUSH_ENABLED", "1")
    monkeypatch.setenv("HERMES_APNS_KEY_FILE", str(key_file))
    monkeypatch.setenv("HERMES_APNS_KEY_ID", "TESTKEY123")
    monkeypatch.setenv("HERMES_APNS_TEAM_ID", "TESTTEAM45")
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    push.register_token(_DEVICE_TOKEN, env="production")

    sent = []
    monkeypatch.setattr(
        push,
        "_send_one",
        lambda conn, *, device_token, headers, body: sent.append(device_token)
        or (200, ""),
    )

    notifier = Notifier(
        NotifierConfig(),
        EventBus(),
        _FakeGateway(owned={"s1"}),
        is_foregrounded=lambda sid: True,  # user IS watching
        push_engine=push,
    )
    assert notifier.observe(_agent_completed()) is None
    assert sent == []
    assert notifier.metrics.suppressed_foreground == 1

    # Blocking gate bypasses the foreground gate and DOES attempt the send.
    approval = Frame(
        sid="s1",
        kind=FrameKind.APPROVAL_REQUEST,
        body={"approval_id": "a1", "title": "Run it?", "description": "rm -rf build/"},
        turn="t1",
    )
    assert notifier.observe(approval) is not None
    assert sent == [_DEVICE_TOKEN]
