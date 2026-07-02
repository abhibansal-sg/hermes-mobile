"""Regression coverage for order-independent hermes-mobile seam wiring."""

from __future__ import annotations

import sys

import pytest

from tests.plugins.hermes_mobile.conftest import _PLUGIN_PKG, load_plugin_module


@pytest.fixture
def plugin_and_ctx():
    """Plugin package plus real context with every touched seam restored."""
    from hermes_cli.dashboard_auth import token_auth
    from hermes_cli.plugins import PluginContext, PluginManager, PluginManifest
    from tools import approval as _approval
    from tui_gateway import server, ws

    load_plugin_module("device_tokens")
    plugin = sys.modules[_PLUGIN_PKG]

    manager = PluginManager()
    manifest = PluginManifest(name="hermes-mobile", key="hermes-mobile")
    ctx = PluginContext(manifest, manager)

    snapshot = {
        token_auth: {
            "TOKEN_AUTHENTICATORS": getattr(token_auth, "TOKEN_AUTHENTICATORS", None),
            "IDENTITY_VALIDATORS": getattr(token_auth, "IDENTITY_VALIDATORS", None),
            "SOCKET_OBSERVERS": getattr(token_auth, "SOCKET_OBSERVERS", None),
        },
        _approval: {"_RESOLVE_OBSERVERS": getattr(_approval, "_RESOLVE_OBSERVERS", None)},
        server: {
            "_EVENT_FANOUT_SUBSCRIBERS": getattr(server, "_EVENT_FANOUT_SUBSCRIBERS", None),
            "_EMIT_OBSERVERS": getattr(server, "_EMIT_OBSERVERS", None),
        },
        ws: {"TRANSPORT_OBSERVERS": getattr(ws, "TRANSPORT_OBSERVERS", None)},
    }
    list_snapshots = {
        (module, name): list(value)
        for module, attrs in snapshot.items()
        for name, value in attrs.items()
        if isinstance(value, list)
    }
    try:
        yield plugin, ctx, manager
    finally:
        for module, attrs in snapshot.items():
            for name, value in attrs.items():
                if value is None:
                    if hasattr(module, name):
                        delattr(module, name)
                    continue
                setattr(module, name, value)
                if isinstance(value, list):
                    value[:] = list_snapshots[(module, name)]


def _contains_named(callbacks, name: str) -> bool:
    return any(getattr(cb, "__name__", "") == name for cb in callbacks)


def test_register_late_wires_every_core_seam_after_attrs_restore(
    plugin_and_ctx, monkeypatch, caplog
):
    """A cold import-order race must not leave any seam permanently unwired.

    The first register() call simulates core modules whose observer lists are not
    fully bound yet.  TOKEN_AUTHENTICATORS intentionally remains present so the
    old implementation half-wires device_tokens.match, then skips
    _validate_device forever on the retry because it gated all three token-auth
    seams behind the authenticator membership check.
    """
    from hermes_cli.dashboard_auth import token_auth
    from tools import approval as _approval
    from tui_gateway import server, ws

    plugin, ctx, manager = plugin_and_ctx
    device_tokens = load_plugin_module("device_tokens")
    push_engine = load_plugin_module("push_engine")
    broadcast = load_plugin_module("broadcast")

    delayed_lists = [
        (token_auth, "IDENTITY_VALIDATORS"),
        (token_auth, "SOCKET_OBSERVERS"),
        (_approval, "_RESOLVE_OBSERVERS"),
        (server, "_EVENT_FANOUT_SUBSCRIBERS"),
        (server, "_EMIT_OBSERVERS"),
        (ws, "TRANSPORT_OBSERVERS"),
    ]
    for module, name in delayed_lists:
        monkeypatch.delattr(module, name, raising=True)

    caplog.clear()
    plugin.register(ctx)

    # The authenticator was present and may have been wired during the partial
    # attempt; that must not prevent the validator/socket seams from wiring when
    # their core lists appear later.
    assert device_tokens.match in token_auth.TOKEN_AUTHENTICATORS

    for module, name in delayed_lists:
        monkeypatch.setattr(module, name, [], raising=False)

    plugin.register(ctx)

    assert device_tokens.match in token_auth.TOKEN_AUTHENTICATORS
    assert _contains_named(token_auth.IDENTITY_VALIDATORS, "_validate_device")
    assert _contains_named(token_auth.SOCKET_OBSERVERS, "_observe_socket")
    assert _contains_named(_approval._RESOLVE_OBSERVERS, "_audit_resolution")
    assert broadcast.on_owner_write in server._EVENT_FANOUT_SUBSCRIBERS
    assert push_engine.handle_gateway_event in server._EMIT_OBSERVERS
    assert broadcast.on_transport in ws.TRANSPORT_OBSERVERS
    assert "mobile-pair" in manager._cli_commands

    monkeypatch.setenv("HERMES_GATEWAY_BROADCAST", "1")

    class _SpyTransport:
        def __init__(self):
            self.broadcasts = []
            self.writes = []
            self._closed = False

        def broadcast(self, obj):
            self.broadcasts.append(obj)
            return True

        def write(self, obj):
            self.writes.append(obj)
            return True

    owner = _SpyTransport()
    mirror = _SpyTransport()
    monkeypatch.setattr(broadcast, "live_transports", lambda: [owner, mirror])
    monkeypatch.setattr(broadcast, "enqueue", lambda transport, obj: transport.broadcast(obj))
    server._sessions["late-wire-sid"] = {
        "session_key": "stored-late-wire",
        "transport": owner,
    }
    try:
        frame = {
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": "message.delta", "session_id": "late-wire-sid"},
        }
        assert server.write_json(frame) is True
    finally:
        server._sessions.pop("late-wire-sid", None)

    assert len(owner.writes) == 1
    assert owner.broadcasts == []
    assert len(mirror.broadcasts) == 1
    assert mirror.broadcasts[0]["params"]["stored_session_id"] == "stored-late-wire"

    warnings = [record.message for record in caplog.records if record.levelname == "WARNING"]
    assert not any("hermes-mobile:" in message for message in warnings)
