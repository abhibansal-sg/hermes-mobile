"""Shared fixtures for the hermes-mobile plugin tests (ABH-88 de-patch, W1).

These tests cover code that moved out of the stock gateway files into
``plugins/hermes-mobile/``:

* ``push_engine``  — APNs + Live Activity engine and the gateway event intake
  (formerly ``hermes_cli/push_notify.py`` + the push block in
  ``tui_gateway/server.py``).
* ``broadcast``    — multi-client fan-out engine (formerly
  ``server._broadcast_event`` + the ``WSTransport`` broadcast queue/drain).
* ``dashboard/api.py`` — REST routes, mounted at ``/api/plugins/hermes-mobile/``.

The plugin package is loaded through the same namespace the stock
PluginManager uses (``hermes_plugins.hermes_mobile``) so module state is
shared with any code that resolves the plugin at runtime.
"""

from __future__ import annotations

import importlib
import importlib.util
import sys
import types
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
PLUGIN_DIR = REPO_ROOT / "plugins" / "hermes-mobile"
_PLUGIN_PKG = "hermes_plugins.hermes_mobile"
_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"


@pytest.fixture(autouse=True)
def mounted_mobile_dashboard_api(_hermetic_environment):
    """Ensure the dashboard loader has mounted the mobile API module.

    ``web_server`` may have been imported during test collection, before the
    per-test HERMES_HOME fixture ran.  If that import saw a disabled plugin in
    the real profile, the module is absent and endpoint tests later fail with a
    KeyError.  Re-run the mount after the hermetic env is active, but only when
    the module is missing so we do not duplicate routes in the shared FastAPI
    app.
    """
    expected_api = (PLUGIN_DIR / "dashboard" / "api.py").resolve()
    mounted_api = sys.modules.get(_API_MODULE_NAME)
    mounted_path = Path(getattr(mounted_api, "__file__", "")).resolve() if mounted_api else None
    if mounted_path != expected_api:
        from hermes_cli import web_server

        # Collection can import web_server before the hermetic HERMES_HOME is
        # active and mount a developer-installed copy of the plugin. Replace
        # those routes with this checkout's bundled plugin so route handlers
        # and test-loaded plugin modules share one registry.
        prefix = "/api/plugins/hermes-mobile"
        web_server.app.routes[:] = [
            route
            for route in web_server.app.routes
            if not str(getattr(route, "path", "")).startswith(prefix)
        ]
        sys.modules.pop(_API_MODULE_NAME, None)
        web_server._get_dashboard_plugins(force_rescan=True)
        route_count = len(web_server.app.routes)
        web_server._mount_plugin_api_routes()
        # The production import mounts plugin APIs before the SPA catch-all.
        # Preserve that ordering for this late test-only recovery.
        added = web_server.app.routes[route_count:]
        if added:
            del web_server.app.routes[route_count:]
            catch_all = next(
                (
                    index
                    for index, route in enumerate(web_server.app.routes)
                    if getattr(route, "path", None) == "/{full_path:path}"
                ),
                len(web_server.app.routes),
            )
            web_server.app.routes[catch_all:catch_all] = added
    assert _API_MODULE_NAME in sys.modules


def load_plugin_module(name: str):
    """Import ``plugins/hermes-mobile/<name>.py`` as a plugin submodule."""
    if _PLUGIN_PKG not in sys.modules:
        if "hermes_plugins" not in sys.modules:
            ns_pkg = types.ModuleType("hermes_plugins")
            ns_pkg.__path__ = []  # type: ignore[attr-defined]
            ns_pkg.__package__ = "hermes_plugins"
            sys.modules["hermes_plugins"] = ns_pkg
        spec = importlib.util.spec_from_file_location(
            _PLUGIN_PKG,
            PLUGIN_DIR / "__init__.py",
            submodule_search_locations=[str(PLUGIN_DIR)],
        )
        mod = importlib.util.module_from_spec(spec)
        mod.__path__ = [str(PLUGIN_DIR)]  # type: ignore[attr-defined]
        sys.modules[_PLUGIN_PKG] = mod
        spec.loader.exec_module(mod)
    return importlib.import_module(f"{_PLUGIN_PKG}.{name}")


@pytest.fixture
def push_engine():
    """The plugin's push_engine module."""
    return load_plugin_module("push_engine")


@pytest.fixture
def broadcast_engine():
    """The plugin's broadcast module."""
    return load_plugin_module("broadcast")


@pytest.fixture
def replay_ring():
    """The plugin's replay_ring module (per-session resumable-stream ring)."""
    return load_plugin_module("replay_ring")


@pytest.fixture
def wired_token_auth():
    """Wire the plugin's device-token registry into the S5 token-auth seam.

    Yields the plugin's ``device_tokens`` module; unwires on teardown so
    other tests see pristine registries.
    """
    import importlib

    from hermes_cli.dashboard_auth import token_auth

    plugin = importlib.import_module(_PLUGIN_PKG) if _PLUGIN_PKG in sys.modules else None
    if plugin is None:
        load_plugin_module("device_tokens")
        plugin = sys.modules[_PLUGIN_PKG]
    device_tokens = load_plugin_module("device_tokens")

    before = (
        list(token_auth.TOKEN_AUTHENTICATORS),
        list(token_auth.IDENTITY_VALIDATORS),
        list(token_auth.SOCKET_OBSERVERS),
    )
    plugin._wire_token_auth()
    try:
        yield device_tokens
    finally:
        token_auth.TOKEN_AUTHENTICATORS[:] = before[0]
        token_auth.IDENTITY_VALIDATORS[:] = before[1]
        token_auth.SOCKET_OBSERVERS[:] = before[2]


@pytest.fixture
def wired_approval_audit():
    """Wire the plugin's audit writer onto the approval resolve-observer seam.

    Yields the plugin's ``audit_log`` module; unwires on teardown.
    """
    import importlib

    from tools import approval as _approval

    if _PLUGIN_PKG not in sys.modules:
        load_plugin_module("audit_log")
    plugin = sys.modules[_PLUGIN_PKG]
    audit_log = load_plugin_module("audit_log")

    before = list(_approval._RESOLVE_OBSERVERS)
    plugin._wire_approval_audit()
    try:
        yield audit_log
    finally:
        _approval._RESOLVE_OBSERVERS[:] = before


@pytest.fixture
def wired_gateway():
    """Gateway server module with the plugin's S1/S2 observers wired.

    Yields ``(server, ws, push_engine, broadcast)`` and unwires afterwards so
    other gateway tests see pristine seam lists.
    """
    from hermes_cli.plugins import (
        PluginContext,
        PluginManifest,
        get_plugin_manager,
    )
    from tui_gateway import server, ws

    push = load_plugin_module("push_engine")
    bcast = load_plugin_module("broadcast")
    manager = get_plugin_manager()
    before = {name: list(callbacks) for name, callbacks in manager._hooks.items()}
    ctx = PluginContext(
        PluginManifest(name="hermes-mobile", key="hermes-mobile"),
        manager,
    )
    push.activate(ctx)
    bcast.activate(ctx)
    try:
        yield server, ws, push, bcast
    finally:
        manager._hooks.clear()
        manager._hooks.update(before)
