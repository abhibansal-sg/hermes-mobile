"""Tests for scripts/ci/classify_changes.py.

Check some common patterns of file modifications and the CI lanes they should run.
We should always fail open. We may run a lane we didn't need, never skip one a
change could have broken.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

_PATH = Path(__file__).resolve().parents[2] / "scripts" / "ci" / "classify_changes.py"
_spec = importlib.util.spec_from_file_location("classify_changes", _PATH)
if _spec is None or _spec.loader is None:
    raise ImportError("Failed to load classify_changes.py")
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
classify = _mod.classify

DEFAULT = {
    "python": True,
    "frontend": True,
    "docker_meta": True,
    "hrp2": True,
    "ios": True,
    "site": True,
    "scan": True,
    "deps": True,
    "mcp_catalog": False,
}


def _lanes(
    python=False,
    frontend=False,
    hrp2=False,
    ios=False,
    site=False,
    scan=False,
    deps=False,
    mcp_catalog=False,
    docker_meta=False,
) -> dict[str, bool]:
    return {
        "python": python,
        "frontend": frontend,
        "docker_meta": docker_meta,
        "hrp2": hrp2,
        "ios": ios,
        "site": site,
        "scan": scan,
        "deps": deps,
        "mcp_catalog": mcp_catalog,
    }


CASES = {
    "docs-only → nothing heavy": (["README.md", "docs/guide.md"], _lanes()),
    "python source → python": (["run_agent.py"], _lanes(python=True, scan=True)),
    "dep manifest → python + hrp2": (
        ["pyproject.toml"],
        _lanes(python=True, hrp2=True, scan=True, deps=True),
    ),
    "uv.lock → python + hrp2": (["uv.lock"], _lanes(python=True, hrp2=True)),
    "ts package → frontend": (["apps/desktop/src/app.tsx"], _lanes(frontend=True)),
    "ui-tui → frontend": (["ui-tui/src/entry.ts"], _lanes(frontend=True)),
    "ios source → ios, not frontend": (
        ["apps/ios/HermesMobile/App/HermesMobileApp.swift"],
        _lanes(ios=True),
    ),
    "ios HRP/2 source → ios + hrp2": (
        ["apps/ios/HermesMobile/RelayV2/RelayV2Client.swift"],
        _lanes(hrp2=True, ios=True),
    ),
    # Lockfile bump shifts every TS package's tree, but not the Python suite.
    "root lockfile → frontend, not python": (["package-lock.json"], _lanes(frontend=True)),
    "website → site": (["website/docs/intro.md"], _lanes(site=True)),
    # SKILL.md reads like docs, but the skill-doc tests read skills/, so a
    # skill edit must still run Python.
    "skill md → python + site": (["skills/github/SKILL.md"], _lanes(python=True, site=True)),
    "dockerfile → docker meta": (["Dockerfile"], _lanes(docker_meta=True)),
    "hadolint config → docker meta": (
        [".hadolint.yaml"],
        _lanes(docker_meta=True),
    ),
    # Unknown top-level file keeps Python on rather than risk a silent skip.
    "unknown toplevel → python": (["Makefile"], _lanes(python=True)),
    "mixed docs+python → python": (["README.md", "agent/x.py"], _lanes(python=True, scan=True)),
    "mixed docs+frontend → frontend": (
        ["README.md", "apps/desktop/x.tsx"],
        _lanes(frontend=True),
    ),
    # Supply-chain lanes
    ".pth file → scan": (["evil.pth"], _lanes(python=True, scan=True)),
    "setup.py → scan": (["setup.py"], _lanes(python=True, scan=True)),
    "mcp catalog manifest → mcp_catalog": (
        ["optional-mcps/foo/manifest.yaml"],
        _lanes(python=True, mcp_catalog=True),
    ),
    "mcp_catalog.py → mcp_catalog": (
        ["hermes_cli/mcp_catalog.py"],
        _lanes(python=True, scan=True, mcp_catalog=True),
    ),
    # HRP/2 has an independently-required workflow. Relay-only changes do not
    # also consume a general Python shard; shared root surfaces still do.
    "standalone relay → hrp2": (
        ["relay/hermes_relay/v2/storage.py"],
        _lanes(hrp2=True, scan=True),
    ),
    "relay hub → hrp2": (
        ["server/relay-hub/relay_hub/app.py"],
        _lanes(hrp2=True, scan=True),
    ),
    "push gateway → hrp2": (
        ["server/push-gateway/push_gateway/app.py"],
        _lanes(hrp2=True, scan=True),
    ),
    "full HRP/2 compose → docker meta + hrp2": (
        ["server/compose.hrp2.yml"],
        _lanes(hrp2=True, docker_meta=True),
    ),
    "Hub-only compose → docker meta + hrp2": (
        ["server/compose.hub-only.yml"],
        _lanes(hrp2=True, docker_meta=True),
    ),
    "standalone Push compose → docker meta + hrp2": (
        ["server/push-gateway/compose.example.yml"],
        _lanes(hrp2=True, docker_meta=True),
    ),
    "Hub Dockerfile → docker meta + hrp2": (
        ["server/relay-hub/Dockerfile"],
        _lanes(hrp2=True, docker_meta=True),
    ),
    "mobile plugin → hrp2": (
        ["plugins/hermes-mobile/mobile_relay_cli.py"],
        _lanes(hrp2=True, scan=True),
    ),
    "HRP/2 protocol fixture → hrp2": (
        ["protocol/hrp2/fixtures/auth-envelope.json"],
        _lanes(hrp2=True),
    ),
    "Swift-produced compatibility fixture → hrp2 + ios": (
        ["tests/fixtures/hrp2/swift-produced-secure-message.json"],
        _lanes(hrp2=True, ios=True),
    ),
    "Swift compatibility producer → hrp2 + ios": (
        ["tests/fixtures/hrp2/SwiftProducedFixture.swift"],
        _lanes(hrp2=True, ios=True),
    ),
    "HRP/2 root evidence → hrp2": (
        ["tests/test_hrp2_conformance_sources.py"],
        _lanes(hrp2=True, scan=True),
    ),
    "shared distribution metadata → python + hrp2": (
        ["MANIFEST.in"],
        _lanes(python=True, hrp2=True),
    ),
    "mixed relay + core → python + hrp2": (
        ["relay/hermes_relay/v2/storage.py", "run_agent.py"],
        _lanes(python=True, hrp2=True, scan=True),
    ),
    # Fail open: CI-config / empty / blank diffs run everything.
    ".github change → all": ([".github/workflows/tests.yml"], DEFAULT),
    "action change → all": ([".github/actions/detect-changes/action.yml"], DEFAULT),
    "empty diff → all": ([], DEFAULT),
    "blank lines → all": (["", "  "], DEFAULT),
}


@pytest.mark.parametrize("files,expected", CASES.values(), ids=CASES.keys())
def test_classify(files, expected):
    assert classify(files) == expected
