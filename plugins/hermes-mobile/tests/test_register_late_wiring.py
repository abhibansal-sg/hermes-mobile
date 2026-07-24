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
            "SESSION_OWNERSHIP_CHECKERS": getattr(
                token_auth, "SESSION_OWNERSHIP_CHECKERS", None
            ),
        },
        _approval: {"_RESOLVE_OBSERVERS": getattr(_approval, "_RESOLVE_OBSERVERS", None)},
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

    plugin, ctx, manager = plugin_and_ctx
    device_tokens = load_plugin_module("device_tokens")
    push_engine = load_plugin_module("push_engine")

    delayed_lists = [
        (token_auth, "IDENTITY_VALIDATORS"),
        (token_auth, "SOCKET_OBSERVERS"),
        (token_auth, "SESSION_OWNERSHIP_CHECKERS"),
        (_approval, "_RESOLVE_OBSERVERS"),
    ]
    for module, name in delayed_lists:
        monkeypatch.delattr(module, name, raising=False)

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
    assert _contains_named(
        token_auth.SESSION_OWNERSHIP_CHECKERS, "_identity_owns_session"
    )
    assert _contains_named(_approval._RESOLVE_OBSERVERS, "_audit_resolution")
    assert push_engine.handle_turn_start in manager._hooks["pre_llm_call"]
    assert push_engine.handle_turn_reply in manager._hooks["post_llm_call"]
    assert push_engine.handle_pre_tool_call in manager._hooks["pre_tool_call"]
    assert push_engine.handle_approval_request in manager._hooks[
        "pre_approval_request"
    ]
    assert "mobile-pair" in manager._cli_commands

    warnings = [record.message for record in caplog.records if record.levelname == "WARNING"]
    assert not any("hermes-mobile:" in message for message in warnings)
