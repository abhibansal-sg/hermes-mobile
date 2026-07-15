"""Integration tests for the hermes-mobile plugin's ``register(ctx)`` entry.

Adversarial-gate finding (W2): every other test wires the seams by calling
``_wire_token_auth()`` / ``_wire_approval_audit()`` / ``activate()`` directly,
so the ONE production wiring path — ``register(ctx)`` invoked by the stock
PluginManager — had zero coverage, and its swallow-all error handling means a
regression there would ship with a green suite. These tests execute the real
entry point with a real ``PluginContext`` and assert every registry it must
populate, plus the ``hermes mobile-pair`` argparse round trip main.py performs
for plugin CLI commands.
"""

from __future__ import annotations

import argparse
import sys

import pytest

from tests.plugins.hermes_mobile.conftest import _PLUGIN_PKG, load_plugin_module


@pytest.fixture
def plugin_and_ctx():
    """The loaded plugin package + a real PluginManager-backed context.

    Snapshots every seam registry the plugin touches and restores them on
    teardown so other tests see pristine state.
    """
    from hermes_cli.dashboard_auth import token_auth
    from hermes_cli.plugins import PluginContext, PluginManager, PluginManifest
    from tools import approval as _approval
    from tui_gateway import server

    load_plugin_module("device_tokens")
    plugin = sys.modules[_PLUGIN_PKG]

    manager = PluginManager()
    manifest = PluginManifest(name="hermes-mobile", key="hermes-mobile")
    ctx = PluginContext(manifest, manager)

    snapshot = (
        list(token_auth.TOKEN_AUTHENTICATORS),
        list(token_auth.IDENTITY_VALIDATORS),
        list(token_auth.SOCKET_OBSERVERS),
        list(_approval._RESOLVE_OBSERVERS),
        list(server.PROMPT_RECEIPT_PROVIDERS),
    )
    try:
        yield plugin, ctx, manager
    finally:
        token_auth.TOKEN_AUTHENTICATORS[:] = snapshot[0]
        token_auth.IDENTITY_VALIDATORS[:] = snapshot[1]
        token_auth.SOCKET_OBSERVERS[:] = snapshot[2]
        _approval._RESOLVE_OBSERVERS[:] = snapshot[3]
        server.PROMPT_RECEIPT_PROVIDERS[:] = snapshot[4]


def test_register_populates_every_seam_registry(plugin_and_ctx):
    from hermes_cli.dashboard_auth import token_auth
    from tools import approval as _approval
    from tui_gateway import server

    plugin, ctx, manager = plugin_and_ctx
    device_tokens = load_plugin_module("device_tokens")
    push_engine = load_plugin_module("push_engine")
    broadcast = load_plugin_module("broadcast")

    plugin.register(ctx)

    # S5 token auth: matcher + validator + socket observers
    assert device_tokens.match in token_auth.TOKEN_AUTHENTICATORS
    assert any(
        getattr(v, "__name__", "") == "_validate_device"
        for v in token_auth.IDENTITY_VALIDATORS
    )
    assert any(
        getattr(o, "__name__", "") == "_observe_socket"
        for o in token_auth.SOCKET_OBSERVERS
    )
    # S5 approval audit observer
    assert any(
        getattr(o, "__name__", "") == "_audit_resolution"
        for o in _approval._RESOLVE_OBSERVERS
    )
    assert any(
        provider.__class__.__name__ == "SQLitePromptReceiptProvider"
        for provider in server.PROMPT_RECEIPT_PROVIDERS
    )
    # S1 + S2 gateway wiring: on a core that ships the tui-gateway observer
    # hooks (this one), the plugin registers HOOKS and leaves the legacy
    # module-level seams EMPTY (double-wiring would double-deliver frames).
    hooks = manager._hooks
    assert any(cb for cb in hooks.get("post_frame_write", [])), "post_frame_write not registered"
    assert any(cb for cb in hooks.get("on_ws_transport_change", [])), "on_ws_transport_change not registered"
    assert any(cb for cb in hooks.get("post_emit_event", [])), "post_emit_event not registered"
    assert push_engine.handle_session_finalize in hooks.get("on_session_finalize", [])
    # CLI command registered on the manager facade
    cmd = manager._cli_commands.get("mobile-pair")
    assert cmd is not None
    assert cmd["plugin"] == "hermes-mobile"
    assert callable(cmd["setup_fn"]) and callable(cmd["handler_fn"])


def test_register_is_idempotent(plugin_and_ctx):
    """A forced re-discovery must not double-wire any seam."""
    from hermes_cli.dashboard_auth import token_auth
    from tools import approval as _approval
    from tui_gateway import server

    plugin, ctx, _manager = plugin_and_ctx
    plugin.register(ctx)
    counts = (
        len(token_auth.TOKEN_AUTHENTICATORS),
        len(token_auth.IDENTITY_VALIDATORS),
        len(token_auth.SOCKET_OBSERVERS),
        len(_approval._RESOLVE_OBSERVERS),
        len(server.PROMPT_RECEIPT_PROVIDERS),
    )
    plugin.register(ctx)
    assert counts == (
        len(token_auth.TOKEN_AUTHENTICATORS),
        len(token_auth.IDENTITY_VALIDATORS),
        len(token_auth.SOCKET_OBSERVERS),
        len(_approval._RESOLVE_OBSERVERS),
        len(server.PROMPT_RECEIPT_PROVIDERS),
    )


def test_register_survives_wiring_failure_without_breaking_host(plugin_and_ctx, monkeypatch):
    """Contract invariant: a wiring failure degrades to stock, never raises."""
    plugin, ctx, manager = plugin_and_ctx
    monkeypatch.setattr(
        plugin, "_wire_token_auth", lambda: (_ for _ in ()).throw(RuntimeError("boom"))
    )
    plugin.register(ctx)  # must not raise
    # The CLI registration (independent wiring) still happened.
    assert "mobile-pair" in manager._cli_commands


def test_mobile_pair_argparse_round_trip(plugin_and_ctx):
    """Replicates main.py's plugin-CLI discovery loop end-to-end."""
    plugin, ctx, manager = plugin_and_ctx
    plugin.register(ctx)
    entry = manager._cli_commands["mobile-pair"]

    parser = argparse.ArgumentParser(prog="hermes")
    subparsers = parser.add_subparsers(dest="command")
    sub = subparsers.add_parser(entry["name"], help=entry["help"])
    entry["setup_fn"](sub)
    sub.set_defaults(func=entry["handler_fn"])

    args = parser.parse_args(["mobile-pair", "--shared-token"])
    assert args.device_token is False
    assert args.func is entry["handler_fn"]

    args_default = parser.parse_args(["mobile-pair"])
    assert args_default.device_token is True
    assert args_default.url is None
