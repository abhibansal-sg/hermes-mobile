"""Tests for HERMES_MOBILE_CONNECTION_JSON env override (ABH-190 step 1).

Verifies that ``_resolve_connection_json_path()`` picks up the env override at
call-time (not import-time), so tests and E2E rigs can point discovery at a
test fixture without touching the user's live connection.json.

All three required assertions per the spec:
  1. With env set → resolved path equals the temp file path.
  2. With env unset → resolved path equals the Desktop app's canonical default.
  3. ``_detect_local_desktop_gateway()`` called with an override path pointing at
     a test connection.json (mode "remote", encoding "plain") returns the URL +
     token from that file — proving the override actually drives discovery.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module

mobile_pair = load_plugin_module("mobile_pair")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_CANONICAL_DEFAULT = (
    Path.home() / "Library" / "Application Support" / "Hermes" / "connection.json"
)


def _write_connection_json(path: Path, payload: dict) -> Path:
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# 1. _resolve_connection_json_path — with env set
# ---------------------------------------------------------------------------


class TestResolveConnectionJsonPathWithEnvSet:
    def test_returns_env_path_when_set(self, tmp_path, monkeypatch):
        """When HERMES_MOBILE_CONNECTION_JSON is set, the resolved path is that value."""
        override = tmp_path / "test_connection.json"
        monkeypatch.setenv("HERMES_MOBILE_CONNECTION_JSON", str(override))
        result = mobile_pair._resolve_connection_json_path()
        assert result == override

    def test_returns_env_path_without_requiring_file_to_exist(self, tmp_path, monkeypatch):
        """Resolution does not require the file to exist — that is the reader's job."""
        override = tmp_path / "nonexistent_conn.json"
        monkeypatch.setenv("HERMES_MOBILE_CONNECTION_JSON", str(override))
        result = mobile_pair._resolve_connection_json_path()
        assert result == override

    def test_re_reads_env_each_call(self, tmp_path, monkeypatch):
        """Re-calls re-read os.environ each time (no import-time cache)."""
        first = tmp_path / "first.json"
        second = tmp_path / "second.json"
        monkeypatch.setenv("HERMES_MOBILE_CONNECTION_JSON", str(first))
        assert mobile_pair._resolve_connection_json_path() == first
        monkeypatch.setenv("HERMES_MOBILE_CONNECTION_JSON", str(second))
        assert mobile_pair._resolve_connection_json_path() == second


# ---------------------------------------------------------------------------
# 2. _resolve_connection_json_path — with env unset
# ---------------------------------------------------------------------------


class TestResolveConnectionJsonPathEnvUnset:
    def test_defaults_to_canonical_desktop_path(self, monkeypatch):
        """With env unset, returns the real ~/Library/.../connection.json path."""
        monkeypatch.delenv("HERMES_MOBILE_CONNECTION_JSON", raising=False)
        result = mobile_pair._resolve_connection_json_path()
        assert result == _CANONICAL_DEFAULT

    def test_empty_env_var_falls_back_to_default(self, monkeypatch):
        """An empty string value is treated the same as unset."""
        monkeypatch.setenv("HERMES_MOBILE_CONNECTION_JSON", "")
        result = mobile_pair._resolve_connection_json_path()
        assert result == _CANONICAL_DEFAULT


# ---------------------------------------------------------------------------
# 3. _detect_local_desktop_gateway — override actually drives discovery
# ---------------------------------------------------------------------------


class TestDetectLocalDesktopGatewayWithOverridePath:
    """Prove the override path is passed through to _detect_local_desktop_gateway
    and that discovery returns the correct URL + token from the test file."""

    def test_remote_plain_via_override_path(self, tmp_path):
        """Passing an explicit override path to _detect_local_desktop_gateway
        returns the URL and token from that test connection.json."""
        conn_file = _write_connection_json(
            tmp_path / "connection.json",
            {
                "mode": "remote",
                "remote": {
                    "url": "https://test-host.ts.net:9119",
                    "token": "TEST_SECRET",
                    "encoding": "plain",
                },
            },
        )
        result = mobile_pair._detect_local_desktop_gateway(conn_file)
        assert result is not None
        assert result.url == "https://test-host.ts.net:9119"
        assert result.token == "TEST_SECRET"
        assert result.manual_token is False
        assert result.source == "connection.json remote"

    def test_env_override_drives_discovery_via_resolve(self, tmp_path, monkeypatch):
        """With HERMES_MOBILE_CONNECTION_JSON set, calling
        _detect_local_desktop_gateway() WITHOUT an explicit path uses the env
        override (resolved via _resolve_connection_json_path inside the function)."""
        conn_file = _write_connection_json(
            tmp_path / "env_connection.json",
            {
                "mode": "remote",
                "remote": {
                    "url": "https://env-override-host.ts.net:9443",
                    "token": "ENV_TOKEN",
                    "encoding": "plain",
                },
            },
        )
        monkeypatch.setenv("HERMES_MOBILE_CONNECTION_JSON", str(conn_file))
        # No explicit path argument — relies on env resolution
        result = mobile_pair._detect_local_desktop_gateway()
        assert result is not None
        assert result.url == "https://env-override-host.ts.net:9443"
        assert result.token == "ENV_TOKEN"
        assert result.manual_token is False

    def test_env_unset_does_not_find_real_desktop_file(self, monkeypatch):
        """When env is unset and the real Desktop file is absent, returns None
        (standard behavior — no regression on the default path)."""
        monkeypatch.delenv("HERMES_MOBILE_CONNECTION_JSON", raising=False)
        # Patch _resolve_connection_json_path to point at a nonexistent path
        # so we don't depend on the developer's live connection.json state.
        import unittest.mock as mock

        with mock.patch.object(
            mobile_pair,
            "_resolve_connection_json_path",
            return_value=Path("/nonexistent/connection.json"),
        ):
            result = mobile_pair._detect_local_desktop_gateway()
        assert result is None
