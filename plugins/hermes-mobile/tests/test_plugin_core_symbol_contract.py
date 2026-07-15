"""The plugin↔core symbol-contract gate must hold in the test suite too.

This is the CI/test-time twin of ``scripts/check_plugin_core_symbols.py`` and of
the promote-gate step in ``scripts/promote-to-staging.sh``. It guards the exact
2026-07-03 outage: an upstream catch-up removed core ``web_server`` auth symbols
that the hermes-mobile plugin still delegated to, 500ing every authenticated
dashboard + mobile call and taking BOTH apps down.

Running it as a test means a broken contract fails ``scripts/run_tests.sh`` (not
just the promote gate), so drift is caught the moment tests run after a merge.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
_GATE = REPO_ROOT / "scripts" / "check_plugin_core_symbols.py"


def _load_gate():
    spec = importlib.util.spec_from_file_location("check_plugin_core_symbols", _GATE)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_symbol_contract_gate_script_exists():
    assert _GATE.is_file(), f"symbol-contract gate script missing at {_GATE}"


def test_plugin_references_no_removed_core_symbols():
    """Every core web_server symbol the plugin references must resolve on core.

    Equivalent to running ``scripts/check_plugin_core_symbols.py`` and asserting
    exit 0 — but in-process so pytest reports the offending symbol directly.
    """
    from hermes_cli import web_server as core

    gate = _load_gate()
    plugin_dir = REPO_ROOT / "plugins" / "hermes-mobile"
    referenced: dict[str, set[str]] = {}
    for py in sorted(plugin_dir.rglob("*.py")):
        if "__pycache__" in py.parts:
            continue
        for sym in gate._referenced_core_symbols(py.read_text(encoding="utf-8")):
            referenced.setdefault(sym, set()).add(str(py.relative_to(REPO_ROOT)))

    missing = {s: files for s, files in referenced.items() if not hasattr(core, s)}
    assert not missing, (
        "hermes-mobile plugin delegates to core web_server symbol(s) that no "
        f"longer exist: {missing}. Inline the helper in the plugin instead."
    )


def test_gate_detects_a_removed_symbol():
    """The gate must actually FAIL when a referenced core symbol is absent.

    A gate that can't go red is worthless. Feed the AST scanner a delegating
    wrapper and confirm the referenced symbol is what a hasattr(core, …) check
    would flag.
    """
    gate = _load_gate()
    src = (
        "def _web():\n"
        "    from hermes_cli import web_server\n"
        "    return web_server\n"
        "def wrapper(request):\n"
        "    return _web()._definitely_not_a_real_core_symbol(request)\n"
    )
    syms = gate._referenced_core_symbols(src)
    assert "_definitely_not_a_real_core_symbol" in syms

    from hermes_cli import web_server as core

    assert not hasattr(core, "_definitely_not_a_real_core_symbol")


def test_gate_ignores_prose_mentions_in_docstrings():
    """Docstring/comment mentions of ``_web()._foo`` must NOT count as references.

    AST-based detection is the whole point — a false positive on prose would make
    the gate flaky and get it disabled.
    """
    gate = _load_gate()
    src = (
        'def wrapper(request):\n'
        '    """Once delegated to _web()._has_dashboard_api_auth — now inlined."""\n'
        '    # _web()._is_device_auth used to live here\n'
        '    return True\n'
    )
    assert gate._referenced_core_symbols(src) == set()
