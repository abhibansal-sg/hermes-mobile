from __future__ import annotations

from tests.plugins.hermes_mobile.conftest import load_plugin_module


def test_relay_lease_enables_existing_broadcast_without_environment(
    monkeypatch,
):
    broadcast = load_plugin_module("broadcast")
    monkeypatch.delenv("HERMES_GATEWAY_BROADCAST", raising=False)
    monkeypatch.setattr(broadcast, "_relay_observer_until", 0.0)

    assert broadcast._broadcast_enabled() is False

    assert broadcast.claim_relay_observer(15.0) == 15.0
    assert broadcast._broadcast_enabled() is True


def test_relay_lease_is_bounded(monkeypatch):
    broadcast = load_plugin_module("broadcast")
    monkeypatch.setattr(broadcast, "_relay_observer_until", 0.0)

    assert broadcast.claim_relay_observer(0.0) == 1.0
    assert broadcast.claim_relay_observer(600.0) == 60.0


def test_relay_lease_expires_back_to_configured_behavior(monkeypatch):
    broadcast = load_plugin_module("broadcast")
    now = [100.0]
    monkeypatch.delenv("HERMES_GATEWAY_BROADCAST", raising=False)
    monkeypatch.setattr(broadcast.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(broadcast, "_relay_observer_until", 0.0)

    broadcast.claim_relay_observer(15.0)
    assert broadcast._broadcast_enabled() is True

    now[0] = 116.0
    assert broadcast._broadcast_enabled() is False
