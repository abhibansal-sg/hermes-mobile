"""Distribution contract for the opt-in HRP/2 Mobile Agent Relay."""

from __future__ import annotations

import tomllib
from pathlib import Path

from tools.lazy_deps import LAZY_DEPS


ROOT = Path(__file__).resolve().parents[1]


def test_root_distribution_bundles_relay_and_declares_opt_in_hpke() -> None:
    project = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    setuptools = project["tool"]["setuptools"]
    package_find = setuptools["packages"]["find"]

    assert "relay" in package_find["where"]
    assert "hermes_relay" in package_find["include"]
    assert "hermes_relay.*" in package_find["include"]
    assert project["project"]["scripts"]["hermes-relay"] == "hermes_relay.__main__:main"
    assert project["project"]["optional-dependencies"]["mobile"] == [
        "pyhpke==0.6.5"
    ]
    assert "graft relay/hermes_relay" in (ROOT / "MANIFEST.in").read_text(
        encoding="utf-8"
    )


def test_mobile_lazy_dependency_matches_extra_exactly() -> None:
    project = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    assert tuple(LAZY_DEPS["mobile.relay"]) == tuple(
        project["project"]["optional-dependencies"]["mobile"]
    )
