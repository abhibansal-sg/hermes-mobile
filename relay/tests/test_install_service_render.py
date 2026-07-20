"""QA-1 B14 — install-service.sh renders the APNs sender env into the plist.

The supervised relay service could NEVER send APNs because the launchd plist's
EnvironmentVariables carried no ``HERMES_PUSH_ENABLED`` / ``HERMES_APNS_*``
(launchd inherits NO shell env). The fix renders them from
``<HERMES_HOME>/apns.env`` / ``RELAY_*`` env at install time. This test runs
the REAL script (launchctl + venv python stubbed so nothing loads/installs)
against a temp HOME and asserts the rendered plist carries the creds — the
config regression that every prior suite missed (they inject a fake
push_engine and never look at the service env).

macOS-only (needs the real ``plutil -lint``); skips elsewhere.
"""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    sys.platform != "darwin", reason="launchd plist install is macOS-only"
)

_SCRIPT = (
    Path(__file__).resolve().parents[2] / "relay" / "scripts" / "install-service.sh"
)


def _stub(path: Path, name: str) -> None:
    p = path / name
    p.write_text("#!/bin/sh\nexit 0\n")
    p.chmod(0o755)


def _run_install(tmp_home: Path, hermes_home: Path, venv: Path) -> Path:
    """Run the real install script into a sandboxed HOME; return the rendered plist."""
    tmp_home.mkdir(parents=True, exist_ok=True)
    stubs = tmp_home / "stubs"
    stubs.mkdir(exist_ok=True)
    _stub(stubs, "launchctl")  # never touch the real service manager
    # Pre-create the venv python (stubbed) so the script skips `python -m venv`
    # and its pip calls become no-ops.
    (venv / "bin").mkdir(parents=True, exist_ok=True)
    _stub(venv / "bin", "python")
    token_file = tmp_home / "dashboard.token"
    token_file.write_text("test-token\n")

    env = dict(os.environ)
    env.update(
        {
            "HOME": str(tmp_home),
            "PATH": f"{stubs}:{env.get('PATH', '')}",
            "RELAY_HERMES_HOME": str(hermes_home),
            "RELAY_TOKEN_FILE": str(token_file),
            "RELAY_SERVICE_VENV": str(venv),
        }
    )
    proc = subprocess.run(
        ["bash", str(_SCRIPT), "install"],
        env=env,
        capture_output=True,
        text=True,
        cwd=str(_SCRIPT.parents[2]),
    )
    assert proc.returncode == 0, f"install failed:\n{proc.stdout}\n{proc.stderr}"
    plist_path = tmp_home / "Library" / "LaunchAgents" / "ai.hermes.relay.plist"
    assert plist_path.is_file(), "plist was not rendered"
    # The REAL plutil must accept it (launchd would reject anything else).
    lint = subprocess.run(
        ["plutil", "-lint", str(plist_path)], capture_output=True, text=True
    )
    assert lint.returncode == 0, lint.stdout + lint.stderr
    return plist_path


def test_install_renders_apns_env_from_apns_env_file(tmp_path):
    """Creds in <HERMES_HOME>/apns.env land in the plist EnvironmentVariables."""
    home = tmp_path / "home"
    hermes_home = tmp_path / "hermes-home"
    hermes_home.mkdir(parents=True)
    (hermes_home / "apns.env").write_text(
        "HERMES_APNS_KEY_FILE=/tmp/qa1-test/apns-key.p8\n"
        "HERMES_APNS_KEY_ID=TESTKEY123\n"
        "HERMES_APNS_TEAM_ID=TESTTEAM45\n"
        "HERMES_APNS_TOPIC=ai.hermes.app\n"
    )
    plist = _run_install(home, hermes_home, tmp_path / "venv")

    with plist.open("rb") as fh:
        data = plistlib.load(fh)
    envvars = data["EnvironmentVariables"]
    assert envvars["HERMES_PUSH_ENABLED"] == "1"  # auto-armed: all creds present
    assert envvars["HERMES_APNS_KEY_FILE"] == "/tmp/qa1-test/apns-key.p8"
    assert envvars["HERMES_APNS_KEY_ID"] == "TESTKEY123"
    assert envvars["HERMES_APNS_TEAM_ID"] == "TESTTEAM45"
    assert envvars["HERMES_APNS_TOPIC"] == "ai.hermes.app"
    # HERMES_HOME is carried too (registry alignment with the gateway).
    assert envvars["HERMES_HOME"] == str(hermes_home)


def test_install_renders_no_push_block_without_creds(tmp_path):
    """Without creds the plist carries NO APNs env (documented no-op) — and is
    still lint-clean; the script prints the owner action instead of failing."""
    home = tmp_path / "home"
    hermes_home = tmp_path / "hermes-home"
    hermes_home.mkdir(parents=True)
    plist = _run_install(home, hermes_home, tmp_path / "venv")

    with plist.open("rb") as fh:
        data = plistlib.load(fh)
    envvars = data["EnvironmentVariables"]
    assert "HERMES_PUSH_ENABLED" not in envvars
    assert "HERMES_APNS_KEY_FILE" not in envvars
    assert "HERMES_HOME" in envvars  # always carried


def test_install_relay_env_overrides_apns_env_file(tmp_path):
    """RELAY_* env takes precedence over apns.env (operator escape hatch)."""
    home = tmp_path / "home"
    hermes_home = tmp_path / "hermes-home"
    hermes_home.mkdir(parents=True)
    (hermes_home / "apns.env").write_text("HERMES_APNS_KEY_ID=FROMFILE00\n")
    venv = tmp_path / "venv"

    stubs = home / "stubs"
    stubs.mkdir(parents=True)
    _stub(stubs, "launchctl")
    (venv / "bin").mkdir(parents=True, exist_ok=True)
    _stub(venv / "bin", "python")
    token_file = home / "dashboard.token"
    token_file.write_text("test-token\n")

    env = dict(os.environ)
    env.update(
        {
            "HOME": str(home),
            "PATH": f"{stubs}:{env.get('PATH', '')}",
            "RELAY_HERMES_HOME": str(hermes_home),
            "RELAY_TOKEN_FILE": str(token_file),
            "RELAY_SERVICE_VENV": str(venv),
            "RELAY_APNS_KEY_ID": "FROMENV123",
            "RELAY_APNS_KEY_FILE": "/tmp/qa1-test/env-key.p8",
            "RELAY_APNS_TEAM_ID": "ENVTEAM789",
        }
    )
    proc = subprocess.run(
        ["bash", str(_SCRIPT), "install"],
        env=env,
        capture_output=True,
        text=True,
        cwd=str(_SCRIPT.parents[2]),
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    with (home / "Library" / "LaunchAgents" / "ai.hermes.relay.plist").open("rb") as fh:
        data = plistlib.load(fh)
    envvars = data["EnvironmentVariables"]
    assert envvars["HERMES_APNS_KEY_ID"] == "FROMENV123"
    assert envvars["HERMES_APNS_TEAM_ID"] == "ENVTEAM789"


def test_relay_package_declares_push_dependencies():
    """The service venv is pip-installed from relay/ — without pyjwt +
    cryptography + httpx[http2] declared there, the armed service still cannot
    mint the ES256 provider JWT (PushDependencyError -> silent no-op)."""
    pyproject = _SCRIPT.parents[1] / "pyproject.toml"
    text = pyproject.read_text(encoding="utf-8")
    assert "pyjwt[crypto]" in text
    assert "cryptography" in text
    assert "httpx[http2]" in text
