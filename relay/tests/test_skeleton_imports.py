"""Smoke: every lane module imports and constructs; skeletons raise cleanly.

Guards the shared surface each lane builds against — the composition root wires
without error and the not-yet-implemented lane methods fail LOUDLY
(NotImplementedError), never silently, so a half-built lane can't ship dark.
"""

from __future__ import annotations

from hermes_relay.app import RelayApp, build_default_config
from hermes_relay.types import Frame, FrameKind


def test_app_wires_all_four_lanes():
    app = RelayApp(build_default_config(gateway_token="test-token", gateway_port=9126))
    assert app.gateway is not None
    assert app.reframer is not None
    assert app.downstream is not None
    assert app.notifier is not None
    # the §6 gate is wired from downstream into the notifier
    assert app.notifier._is_foregrounded == app.downstream.session_has_live_phone
    # default gateway port is the isolated test range, never 9119
    assert app.gateway._cfg.port != 9119


def test_reframer_reframe_is_implemented():
    # Lane 2 is now live: reframe() maps a raw event to downstream item frames.
    app = RelayApp(build_default_config(gateway_token="t"))
    frames = app.reframer.reframe(_dummy_event())
    assert frames  # a message.delta yields turn.started + item.started + item.delta
    assert all(isinstance(f, Frame) for f in frames)
    assert FrameKind.ITEM_DELTA in {f.kind for f in frames}


def test_downstream_gate_defaults_false_with_no_connections():
    app = RelayApp(build_default_config(gateway_token="t"))
    assert app.downstream.session_has_live_phone("any-sid") is False


def _dummy_event():
    from hermes_relay.types import GatewayEvent

    return GatewayEvent(type="message.delta", session_id="s", payload={"text": "x"})
