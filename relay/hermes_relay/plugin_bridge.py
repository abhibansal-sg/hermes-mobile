"""Bridge to the small ``plugins/hermes-mobile`` gateway adapter.

The transparent proxy reuses the plugin's ``device_tokens`` registry to
authenticate scoped phone credentials and its existing APNs engine to deliver
stock gateway events. Conversation behavior remains in the stock gateway.

The plugin directory is named ``hermes-mobile`` (a hyphen), so it is NOT
importable by dotted name; the stock gateway loads it by file path. The relay
does the same: it locates the plugin dir and puts it on ``sys.path``. This is
the ONLY place that reaches
across into the plugin tree, keeping the coupling auditable.

Locating the plugin dir (in priority order):
1. ``$HERMES_RELAY_PLUGIN_DIR`` if set (explicit override, e.g. tests).
2. ``$HERMES_REPO_ROOT/plugins/hermes-mobile`` if ``HERMES_REPO_ROOT`` is set.
3. Walk up from this file until a ``plugins/hermes-mobile`` dir is found (works
   in-worktree without any env).
"""

from __future__ import annotations

import os
import sys
import importlib
import importlib.util
from pathlib import Path
from typing import Optional

_PLUGIN_REL = Path("plugins") / "hermes-mobile"
_cached_dir: Optional[Path] = None


def find_plugin_dir() -> Path:
    """Resolve the ``plugins/hermes-mobile`` directory. Raises if not found."""
    global _cached_dir
    if _cached_dir is not None:
        return _cached_dir

    override = os.environ.get("HERMES_RELAY_PLUGIN_DIR")
    if override:
        p = Path(override)
        if (p / "replay_ring.py").exists():
            _cached_dir = p
            return p

    root = os.environ.get("HERMES_REPO_ROOT")
    if root:
        p = Path(root) / _PLUGIN_REL
        if (p / "replay_ring.py").exists():
            _cached_dir = p
            return p

    here = Path(__file__).resolve()
    for parent in here.parents:
        cand = parent / _PLUGIN_REL
        if (cand / "replay_ring.py").exists():
            _cached_dir = cand
            return cand

    raise RuntimeError(
        "Could not locate plugins/hermes-mobile; set HERMES_RELAY_PLUGIN_DIR "
        "or HERMES_REPO_ROOT."
    )


def repo_root() -> Path:
    """The monorepo root (``plugins/hermes-mobile`` -> ../..).

    The reused plumbing imports repo-root-relative modules (``utils``,
    ``hermes_state``, etc.), so the root must be importable too.
    """
    return find_plugin_dir().parent.parent


def ensure_on_path() -> Path:
    """Put the plugin dir AND repo root on ``sys.path`` (idempotent).

    Returns the plugin dir. Both entries are needed: the plugin modules import
    each other as top-level names (plugin dir) and import repo-root modules such
    as ``utils`` (repo root).
    """
    plugin_dir = find_plugin_dir()
    for p in (str(plugin_dir), str(repo_root())):
        if p not in sys.path:
            sys.path.insert(0, p)
    return plugin_dir


def import_device_tokens():
    """Import and return the reused ``device_tokens`` module."""
    ensure_on_path()
    import device_tokens  # type: ignore

    return device_tokens


def import_push_engine():
    """Import and return the existing APNs implementation."""
    plugin_dir = ensure_on_path()
    package_name = "_hermes_mobile_relay_adapter"
    if package_name not in sys.modules:
        spec = importlib.util.spec_from_file_location(
            package_name,
            plugin_dir / "__init__.py",
            submodule_search_locations=[str(plugin_dir)],
        )
        if spec is None or spec.loader is None:
            raise ImportError(f"cannot load hermes-mobile plugin from {plugin_dir}")
        package = importlib.util.module_from_spec(spec)
        sys.modules[package_name] = package
        spec.loader.exec_module(package)
    return importlib.import_module(f"{package_name}.push_engine")
