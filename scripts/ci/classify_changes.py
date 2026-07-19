#!/usr/bin/env python3
"""Classify a PR's changed files into CI work lanes.

Reads newline-separated changed paths on stdin and writes ``key=value``
booleans (one per lane) to ``$GITHUB_OUTPUT`` and stdout. The
``detect-changes`` composite action consumes them so steps gate on
``if: steps.changes.outputs.<lane> == 'true'``.

Lanes:

* ``python``      — pytest / ruff / ty / footguns.
* ``docker_meta`` — Dockerfiles etc.
* ``frontend``    — TS typecheck matrix + desktop build.
* ``hrp2``        — Mobile Relay v2 packages, servers, plugin, and evidence.
* ``ios``         — HermesMobile Xcode project and tests.
* ``site``        — Docusaurus + generated skill docs.
* ``scan``        — supply-chain scan (Python files, .pth, setup hooks).
* ``deps``        — pyproject.toml dependency bounds check.
* ``mcp_catalog`` — bundled MCP catalog / installer review.

Docker is not a lane — it builds on push-to-main and release only,
never per-PR.

Contract — *fail open, never closed*. We may run a lane we didn't need, but
must never skip one a change could break:

* An empty diff, or any ``.github/`` change, runs everything.
* ``python`` is a denylist: skipped only when *every* file is provably prose,
  a frontend/iOS-only package, or owned by the independently-required HRP/2
  lane; an unrecognized path keeps it on.
* ``skills/`` (incl. ``SKILL.md``) is python-relevant — the skill-doc tests
  read that tree, so a doc-looking edit can still break Python.
"""

from __future__ import annotations

import os
import sys

_FRONTEND = (
    "ui-tui/",
    "web/",
    "apps/bootstrap-installer/",
    "apps/desktop/",
    "apps/shared/",
)  # TS typecheck-matrix packages; native apps/ios has a dedicated lane.
_IOS = ("apps/ios/",)
_IOS_COMPAT_FIXTURE_FILES = {
    "tests/fixtures/hrp2/SwiftProducedFixture.swift",
    "tests/fixtures/hrp2/swift-produced-secure-message.json",
}
_ROOT_NPM = {"package.json", "package-lock.json"}  # shifts every package's tree
_HRP2_DOCKER_META = (
    "server/compose.hrp2.yml",
    "server/compose.hub-only.yml",
    "server/relay-hub/Dockerfile",
    "server/relay-hub/.dockerignore",
    "server/push-gateway/Dockerfile",
    "server/push-gateway/.dockerignore",
    "server/push-gateway/compose.example.yml",
)
_DOCKER_META = (
    "docker/",
    ".hadolint.yaml",
    ".hadolint.yml",
    "Dockerfile",
) + _HRP2_DOCKER_META  # docker setup and deploy manifests
_SITE = ("website/", "skills/", "optional-skills/")  # docs site + skill pages

# HRP/2 owns these paths end-to-end in .github/workflows/hrp2-tests.yml. Keeping
# them out of the general Python shard avoids running the same root/plugin tests
# twice for a Relay-only PR. Shared root packaging/config files remain Python
# relevant and are listed separately in _HRP2_SHARED_FILES below.
_HRP2_OWNED = (
    "relay/",
    "server/relay-hub/",
    "server/push-gateway/",
    "protocol/hrp2/",
    "plugins/hermes-mobile/",
    "tests/plugins/hermes_mobile/",
    "tests/fixtures/hrp2/",
)
_HRP2_OWNED_FILES = {
    "server/compose.hrp2.yml",
    "server/compose.hub-only.yml",
    "tests/e2e/test_hrp2_agent_hub.py",
    "tests/e2e/test_hrp2_privacy_evidence.py",
    "tests/test_hrp2_conformance_sources.py",
    "tests/test_mobile_relay_distribution.py",
}
_HRP2_SHARED_FILES = {
    "MANIFEST.in",
    "pyproject.toml",
    "uv.lock",
    "tools/lazy_deps.py",
    "hermes_cli/service_manager.py",
}
_HRP2_IOS = (
    "apps/ios/HermesMobile/RelayV2/",
    "apps/ios/HermesMobileTests/RelayV2Tests.swift",
    "apps/ios/HermesNotificationService/",
)

# Prose/frontend/native trees that can't touch Python. skills/ is excluded on
# purpose. HRP/2-owned paths are handled by their required reusable workflow.
_PY_SKIP = ("docs/", "website/") + _FRONTEND + _IOS + _HRP2_OWNED

# Supply-chain scan: files that can execute code at install/import time.
_SCAN_EXTS = (".py", ".pth")
_SCAN_FILES = {"setup.cfg", "pyproject.toml"}

# MCP catalog files that require explicit security review.
_MCP_CATALOG_PATHS = ("optional-mcps/",)
_MCP_CATALOG_FILES = {"hermes_cli/mcp_catalog.py"}

def _is_docs(p: str) -> bool:
    if p.startswith(("skills/", "optional-skills/")):
        return False
    return p.endswith((".md", ".mdx")) or p.startswith("docs/") or p.startswith("LICENSE")


def _py_irrelevant(p: str) -> bool:
    return (
        _is_docs(p)
        or p in _ROOT_NPM
        or p in _HRP2_OWNED_FILES
        or p.startswith(_PY_SKIP)
        or p.startswith(_DOCKER_META)
    )


def _is_scan(p: str) -> bool:
    return p.endswith(_SCAN_EXTS) or p in _SCAN_FILES


def _is_mcp_catalog(p: str) -> bool:
    return p.startswith(_MCP_CATALOG_PATHS) or p in _MCP_CATALOG_FILES


def _is_hrp2(p: str) -> bool:
    return (
        p.startswith(_HRP2_OWNED)
        or p in _HRP2_OWNED_FILES
        or p in _HRP2_SHARED_FILES
        or p.startswith(_HRP2_IOS)
    )


def _is_ios(p: str) -> bool:
    return p.startswith(_IOS) or p in _IOS_COMPAT_FIXTURE_FILES


def classify(files: list[str]) -> dict[str, bool]:
    """Map changed paths to ``{lane: should_run}``."""
    files = [f.strip() for f in files if f.strip()]
    ret = {
        "python": any(not _py_irrelevant(f) for f in files),
        "docker_meta": any(f.startswith(_DOCKER_META) for f in files),
        "frontend": any(f.startswith(_FRONTEND) or f in _ROOT_NPM for f in files),
        "hrp2": any(_is_hrp2(f) for f in files),
        "ios": any(_is_ios(f) for f in files),
        "site": any(f.startswith(_SITE) for f in files),
        "scan": any(_is_scan(f) for f in files),
        "deps": any(f == "pyproject.toml" for f in files),
        "mcp_catalog": any(_is_mcp_catalog(f) for f in files),
    }
    if not files or any(f.startswith(".github/") for f in files):
        ret["python"] = True
        ret["docker_meta"] = True
        ret["frontend"] = True
        ret["hrp2"] = True
        ret["ios"] = True
        ret["site"] = True
        ret["scan"] = True
        ret["deps"] = True

        # explicitly skip mcp catalog here. it's not needed unless those files are modified.
    return ret



def main() -> int:
    lanes = classify(sys.stdin.read().splitlines())
    out = "\n".join(f"{k}={str(v).lower()}" for k, v in lanes.items())
    if dest := os.environ.get("GITHUB_OUTPUT"):
        with open(dest, "a", encoding="utf-8") as fh:
            fh.write(out + "\n")
    print(out)  # echo for local runs + CI step logs
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
