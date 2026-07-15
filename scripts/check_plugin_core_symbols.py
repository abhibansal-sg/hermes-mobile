#!/usr/bin/env python3
"""Verify the hermes-mobile plugin never calls a core web_server symbol that was removed.

WHY THIS EXISTS (2026-07-03 outage, same drift class the catch-up hardening
targets): the big upstream catch-up refactored core auth out of
``hermes_cli.web_server`` (the four ``_has_dashboard_api_auth`` /
``_is_device_auth`` / ``_request_device`` / ``_device_has_scope`` helpers moved
into ``hermes_cli/dashboard_auth/*``). The dashboard/mobile plugin still
delegated to those now-missing core symbols via ``_web()._<sym>`` wrappers, so
EVERY authenticated dashboard + WebSocket call raised ``AttributeError`` -> 500,
taking down BOTH the desktop and mobile apps at once (one plugin serves both).

The static grep + import check here turns that runtime AttributeError into a
promote-time FAIL. It scans the plugin for every ``_web().<name>`` (and
``web_server.<name>``) reference and asserts each referenced symbol actually
exists on the current core ``hermes_cli.web_server`` module. Any missing symbol
fails the gate before promote — never in production again.

Run it after any upstream merge / catch-up, and from the promote gate.

Exit codes:
  0 — every referenced core symbol resolves on hermes_cli.web_server
  1 — one or more referenced symbols are missing from core (BROKEN CONTRACT)
  2 — script/usage error (could not import core, plugin dir missing, etc.)

Usage:
  python scripts/check_plugin_core_symbols.py
  python scripts/check_plugin_core_symbols.py --plugin plugins/hermes-mobile
"""

from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
DEFAULT_PLUGIN = REPO_ROOT / "plugins" / "hermes-mobile"

# Dunder / obviously-non-symbol attributes we never treat as a contract call.
_IGNORE = {"__class__", "__dict__", "__name__", "__doc__", "__file__"}


class _CoreSymbolVisitor(ast.NodeVisitor):
    """Collect every ``hermes_cli.web_server`` attribute the AST actually accesses.

    AST (not regex) so docstrings, comments, and string literals that merely
    *mention* ``_web()._foo`` are never counted — only real attribute-access
    nodes are. Three contract shapes are recognised:

      1. ``_web().<attr>``                 — inline accessor call
      2. ``web = _web()`` then ``web.<attr>`` — locally-aliased module handle
      3. ``web_server.<attr>``             — a direct ``from hermes_cli import
                                             web_server`` reference

    For (2) we track every local name bound to a ``_web()`` call (or imported as
    ``web_server``) and treat ``<name>.<attr>`` as a core reference.
    """

    def __init__(self) -> None:
        # Names locally bound to the web_server module.
        self.web_aliases: set[str] = {"web_server"}
        self.referenced: set[str] = set()

    def _is_web_call(self, node: ast.AST) -> bool:
        return (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "_web"
        )

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        if node.module == "hermes_cli":
            for alias in node.names:
                if alias.name == "web_server":
                    self.web_aliases.add(alias.asname or "web_server")
        self.generic_visit(node)

    def visit_Assign(self, node: ast.Assign) -> None:
        # Track ``web = _web()`` (and any ``x = web_server``) alias bindings.
        if self._is_web_call(node.value) or (
            isinstance(node.value, ast.Name) and node.value.id in self.web_aliases
        ):
            for tgt in node.targets:
                if isinstance(tgt, ast.Name):
                    self.web_aliases.add(tgt.id)
        self.generic_visit(node)

    def visit_Attribute(self, node: ast.Attribute) -> None:
        val = node.value
        hit = False
        # Shape 1: ``_web().<attr>``
        if self._is_web_call(val):
            hit = True
        # Shape 2/3: ``<alias>.<attr>`` where alias is bound to the module.
        elif isinstance(val, ast.Name) and val.id in self.web_aliases:
            hit = True
        if hit and node.attr not in _IGNORE:
            self.referenced.add(node.attr)
        self.generic_visit(node)


def _referenced_core_symbols(py_text: str) -> set[str]:
    """Every core web_server attribute the source AST references (prose ignored)."""
    tree = ast.parse(py_text)  # SyntaxError -> caught by caller as a hard fail
    v = _CoreSymbolVisitor()
    v.visit(tree)
    return v.referenced


def _static_web_server_symbols() -> set[str]:
    """Top-level symbols defined by hermes_cli/web_server.py.

    This keeps ``python3 scripts/check_plugin_core_symbols.py`` useful on a
    machine whose bare ``python3`` does not have the repo's optional/runtime deps
    installed. The preferred path still imports ``hermes_cli.web_server``; this
    fallback only answers the narrow symbol-existence question from source.
    """
    web_server_py = REPO_ROOT / "hermes_cli" / "web_server.py"
    tree = ast.parse(web_server_py.read_text(encoding="utf-8"))
    symbols: set[str] = set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            symbols.add(node.name)
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for tgt in targets:
                if isinstance(tgt, ast.Name):
                    symbols.add(tgt.id)
    return symbols


def _core_has_symbol_checker():
    """Return (has_symbol, mode) for the current core web_server contract."""
    try:
        from hermes_cli import web_server as core

        return (lambda sym: hasattr(core, sym)), "import"
    except Exception as exc:  # pragma: no cover - env break / bare python3 fallback
        try:
            symbols = _static_web_server_symbols()
        except Exception as static_exc:
            print(
                "[symbol-contract] ERROR: cannot import hermes_cli.web_server: "
                f"{exc}; static fallback also failed: {static_exc}",
                file=sys.stderr,
            )
            return None, "error"
        print(
            "[symbol-contract] WARN: cannot import hermes_cli.web_server "
            f"({exc}); using static source fallback",
            file=sys.stderr,
        )
        return (lambda sym: sym in symbols), "static"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--plugin",
        default=str(DEFAULT_PLUGIN),
        help="plugin dir to scan (default: plugins/hermes-mobile)",
    )
    args = ap.parse_args()

    plugin_dir = Path(args.plugin)
    if not plugin_dir.is_dir():
        print(f"[symbol-contract] ERROR: plugin dir not found: {plugin_dir}", file=sys.stderr)
        return 2

    has_core_symbol, mode = _core_has_symbol_checker()
    if has_core_symbol is None:
        return 2

    referenced: dict[str, set[Path]] = {}
    for py in sorted(plugin_dir.rglob("*.py")):
        if "__pycache__" in py.parts:
            continue
        try:
            text = py.read_text(encoding="utf-8")
        except Exception:
            continue
        try:
            syms = _referenced_core_symbols(text)
        except SyntaxError as exc:
            print(f"[symbol-contract] ERROR: {py} does not parse: {exc}", file=sys.stderr)
            return 2
        for s in syms:
            try:
                rel = py.relative_to(REPO_ROOT)
            except ValueError:
                rel = py
            referenced.setdefault(s, set()).add(rel)

    missing = {s: files for s, files in referenced.items() if not has_core_symbol(s)}

    if missing:
        print("[symbol-contract] BROKEN CONTRACT — plugin references core symbols "
              "that no longer exist on hermes_cli.web_server:", file=sys.stderr)
        for s in sorted(missing):
            where = ", ".join(str(p) for p in sorted(missing[s]))
            print(f"  - _web().{s}  <- referenced in: {where}", file=sys.stderr)
        print("\nFIX: inline the helper in the plugin (own the logic) instead of "
              "delegating to the removed core symbol, then re-run this check.",
              file=sys.stderr)
        return 1

    checked = ", ".join(sorted(referenced)) or "(none)"
    print(f"[symbol-contract] OK — all {len(referenced)} core symbol(s) referenced by "
          f"{plugin_dir.name} resolve on hermes_cli.web_server: {checked}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
