"""Tests for Increment 3a — plugin-side Desktop gateway discovery.

Covers ``_detect_local_desktop_gateway()``, ``_read_connection_json()``,
``_probe_local_gateway_port()``, and the wiring into ``_detect_dashboard_url()``.

All filesystem access is via ``tmp_path``; all network probes are mocked.
No live gateway is contacted.
"""

from __future__ import annotations

import json
import urllib.error
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module

mobile_pair = load_plugin_module("mobile_pair")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_connection_json(tmp_path: Path, payload: dict) -> Path:
    """Write ``connection.json`` into ``tmp_path`` and return the path."""
    p = tmp_path / "connection.json"
    p.write_text(json.dumps(payload), encoding="utf-8")
    return p


# ---------------------------------------------------------------------------
# _read_connection_json
# ---------------------------------------------------------------------------


class TestReadConnectionJson:
    def test_returns_dict_for_valid_json(self, tmp_path):
        p = _write_connection_json(tmp_path, {"mode": "remote"})
        assert mobile_pair._read_connection_json(p) == {"mode": "remote"}

    def test_returns_none_for_missing_file(self, tmp_path):
        assert mobile_pair._read_connection_json(tmp_path / "nonexistent.json") is None

    def test_returns_none_for_malformed_json(self, tmp_path):
        p = tmp_path / "connection.json"
        p.write_text("not json {{{ }", encoding="utf-8")
        assert mobile_pair._read_connection_json(p) is None

    def test_returns_none_for_json_non_dict(self, tmp_path):
        p = tmp_path / "connection.json"
        p.write_text('["list", "not", "dict"]', encoding="utf-8")
        assert mobile_pair._read_connection_json(p) is None

    def test_returns_none_for_empty_file(self, tmp_path):
        p = tmp_path / "connection.json"
        p.write_text("", encoding="utf-8")
        assert mobile_pair._read_connection_json(p) is None


# ---------------------------------------------------------------------------
# _probe_local_gateway_port — mocked HTTP
# ---------------------------------------------------------------------------


class _FakeProbeResp:
    """Minimal fake HTTP response for ``_probe_local_gateway_port`` tests."""

    def __init__(self, status: int, body: bytes):
        self.status = status
        self._body = body

    def read(self, n: int = -1) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class TestProbeLocalGatewayPort:
    def _patched_urlopen(self, resp):
        return patch("urllib.request.urlopen", return_value=resp)

    def test_returns_true_for_valid_status_response(self):
        body = json.dumps({"status": "ok"}).encode()
        resp = _FakeProbeResp(200, body)
        with self._patched_urlopen(resp):
            assert mobile_pair._probe_local_gateway_port(9119) is True

    def test_returns_false_for_non_200(self):
        resp = _FakeProbeResp(503, b"{}")
        with self._patched_urlopen(resp):
            assert mobile_pair._probe_local_gateway_port(9119) is False

    def test_returns_false_for_missing_status_key(self):
        body = json.dumps({"something": "else"}).encode()
        resp = _FakeProbeResp(200, body)
        with self._patched_urlopen(resp):
            assert mobile_pair._probe_local_gateway_port(9119) is False

    def test_returns_false_on_connection_refused(self):
        with patch(
            "urllib.request.urlopen",
            side_effect=urllib.error.URLError("connection refused"),
        ):
            assert mobile_pair._probe_local_gateway_port(9120) is False

    def test_returns_false_for_non_dict_json_body(self):
        resp = _FakeProbeResp(200, b'["not", "a", "dict"]')
        with self._patched_urlopen(resp):
            assert mobile_pair._probe_local_gateway_port(9119) is False

    def test_returns_false_for_malformed_json_body(self):
        resp = _FakeProbeResp(200, b"not json")
        with self._patched_urlopen(resp):
            assert mobile_pair._probe_local_gateway_port(9119) is False

    def test_probes_only_loopback(self):
        """Verify the constructed URL always targets 127.0.0.1 (loopback only)."""
        captured = {}

        def _capture(req, timeout=None):
            captured["url"] = req.full_url
            raise urllib.error.URLError("stop")

        with patch("urllib.request.urlopen", side_effect=_capture):
            mobile_pair._probe_local_gateway_port(9150)

        assert "127.0.0.1" in captured["url"]
        assert "9150" in captured["url"]


# ---------------------------------------------------------------------------
# _detect_local_desktop_gateway — remote mode
# ---------------------------------------------------------------------------


class TestDetectLocalDesktopGatewayRemoteMode:
    def test_remote_plain_returns_url_and_token(self, tmp_path):
        p = _write_connection_json(
            tmp_path,
            {
                "mode": "remote",
                "remote": {
                    "url": "https://my-mac.ts.net:9119",
                    "token": "SECRET",
                    "encoding": "plain",
                },
            },
        )
        result = mobile_pair._detect_local_desktop_gateway(p)
        assert result is not None
        assert result.url == "https://my-mac.ts.net:9119"
        assert result.token == "SECRET"
        assert result.manual_token is False
        assert result.source == "connection.json remote"

    def test_remote_plain_missing_token_sets_manual_token(self, tmp_path):
        p = _write_connection_json(
            tmp_path,
            {
                "mode": "remote",
                "remote": {"url": "https://my-mac.ts.net:9119", "encoding": "plain"},
            },
        )
        result = mobile_pair._detect_local_desktop_gateway(p)
        assert result is not None
        assert result.url == "https://my-mac.ts.net:9119"
        assert result.token is None
        assert result.manual_token is True

    def test_remote_safestorage_returns_url_only_manual_token(self, tmp_path):
        p = _write_connection_json(
            tmp_path,
            {
                "mode": "remote",
                "remote": {
                    "url": "https://my-mac.ts.net:9119",
                    "encoding": "safeStorage",
                    "token": "ENCRYPTED_BLOB",
                },
            },
        )
        result = mobile_pair._detect_local_desktop_gateway(p)
        assert result is not None
        assert result.url == "https://my-mac.ts.net:9119"
        assert result.token is None
        assert result.manual_token is True
        assert "safeStorage" in result.source.lower() or "encrypted" in result.source.lower()

    def test_remote_unknown_encoding_returns_url_only_manual_token(self, tmp_path):
        p = _write_connection_json(
            tmp_path,
            {
                "mode": "remote",
                "remote": {
                    "url": "https://my-mac.ts.net:9119",
                    "encoding": "keychain",
                    "token": "some_blob",
                },
            },
        )
        result = mobile_pair._detect_local_desktop_gateway(p)
        assert result is not None
        assert result.manual_token is True
        assert result.token is None

    def test_remote_mode_empty_url_returns_none(self, tmp_path):
        p = _write_connection_json(
            tmp_path,
            {"mode": "remote", "remote": {"url": "", "encoding": "plain"}},
        )
        assert mobile_pair._detect_local_desktop_gateway(p) is None

    def test_remote_mode_missing_remote_block_returns_none(self, tmp_path):
        p = _write_connection_json(tmp_path, {"mode": "remote"})
        assert mobile_pair._detect_local_desktop_gateway(p) is None

    def test_remote_mode_non_dict_remote_block_returns_none(self, tmp_path):
        p = _write_connection_json(
            tmp_path, {"mode": "remote", "remote": "not-a-dict"}
        )
        assert mobile_pair._detect_local_desktop_gateway(p) is None

    def test_remote_default_encoding_plain_reads_token(self, tmp_path):
        """When ``encoding`` key is absent the default is ``plain``."""
        p = _write_connection_json(
            tmp_path,
            {
                "mode": "remote",
                "remote": {"url": "https://my-mac.ts.net:9119", "token": "MYTOKEN"},
            },
        )
        result = mobile_pair._detect_local_desktop_gateway(p)
        assert result is not None
        assert result.token == "MYTOKEN"
        assert result.manual_token is False


# ---------------------------------------------------------------------------
# _detect_local_desktop_gateway — local mode (port probe)
# ---------------------------------------------------------------------------


class TestDetectLocalDesktopGatewayLocalMode:
    def test_local_mode_probe_hits_first_responding_port(self, tmp_path):
        p = _write_connection_json(tmp_path, {"mode": "local"})

        def _probe(port):
            return port == 9135  # only this port "responds"

        with patch.object(mobile_pair, "_probe_local_gateway_port", side_effect=_probe):
            result = mobile_pair._detect_local_desktop_gateway(p)

        assert result is not None
        assert result.url == "http://127.0.0.1:9135"
        assert result.token is None
        assert result.manual_token is True
        assert "9135" in result.source

    def test_local_mode_probe_uses_9119_first(self, tmp_path):
        """9119 is the first port probed (common case: user already has dashboard)."""
        p = _write_connection_json(tmp_path, {"mode": "local"})
        probed = []

        def _probe(port):
            probed.append(port)
            return port == 9119

        with patch.object(mobile_pair, "_probe_local_gateway_port", side_effect=_probe):
            result = mobile_pair._detect_local_desktop_gateway(p)

        assert probed[0] == 9119
        assert result is not None
        assert result.url == "http://127.0.0.1:9119"

    def test_local_mode_no_responding_port_returns_none(self, tmp_path):
        p = _write_connection_json(tmp_path, {"mode": "local"})

        with patch.object(
            mobile_pair, "_probe_local_gateway_port", return_value=False
        ):
            assert mobile_pair._detect_local_desktop_gateway(p) is None

    def test_local_mode_stops_at_first_responding_port(self, tmp_path):
        """Discovery must stop as soon as one port responds — no over-probing."""
        p = _write_connection_json(tmp_path, {"mode": "local"})
        probed = []

        def _probe(port):
            probed.append(port)
            return port == 9122  # third candidate

        with patch.object(mobile_pair, "_probe_local_gateway_port", side_effect=_probe):
            result = mobile_pair._detect_local_desktop_gateway(p)

        # Ports before 9122 in _LOCAL_PROBE_PORTS: 9119, 9120, 9121, then 9122
        assert result is not None
        assert result.url == "http://127.0.0.1:9122"
        # Must not have probed past 9122
        assert 9123 not in probed


# ---------------------------------------------------------------------------
# _detect_local_desktop_gateway — absent / garbage connection.json
# ---------------------------------------------------------------------------


class TestDetectLocalDesktopGatewayEdgeCases:
    def test_missing_connection_json_returns_none(self, tmp_path):
        assert (
            mobile_pair._detect_local_desktop_gateway(tmp_path / "nope.json") is None
        )

    def test_garbage_json_returns_none(self, tmp_path):
        p = tmp_path / "connection.json"
        p.write_text("{{{{ garbage !!!}", encoding="utf-8")
        assert mobile_pair._detect_local_desktop_gateway(p) is None

    def test_unknown_mode_returns_none(self, tmp_path):
        p = _write_connection_json(tmp_path, {"mode": "exotic"})
        assert mobile_pair._detect_local_desktop_gateway(p) is None

    def test_missing_mode_key_returns_none(self, tmp_path):
        p = _write_connection_json(tmp_path, {"remote": {"url": "http://x"}})
        assert mobile_pair._detect_local_desktop_gateway(p) is None


# ---------------------------------------------------------------------------
# _detect_dashboard_url wiring — Desktop discovery runs BEFORE Tailscale Serve
# ---------------------------------------------------------------------------


class TestDetectDashboardUrlWiring:
    def test_remote_desktop_gateway_wins_over_tailscale_serve(self, tmp_path, monkeypatch):
        """When connection.json has a remote URL, Tailscale Serve is never called."""
        p = _write_connection_json(
            tmp_path,
            {
                "mode": "remote",
                "remote": {"url": "https://my-mac.ts.net:9443", "encoding": "plain"},
            },
        )
        monkeypatch.setattr(
            mobile_pair,
            "_detect_local_desktop_gateway",
            lambda path=None: mobile_pair._DesktopGatewayResult(
                url="https://my-mac.ts.net:9443",
                token=None,
                manual_token=True,
                source="connection.json remote",
            ),
        )
        tailscale_called = {"called": False}

        def _fake_ts():
            tailscale_called["called"] = True
            return None

        monkeypatch.setattr(mobile_pair, "_tailscale_serve_status", _fake_ts)

        url = mobile_pair._detect_dashboard_url()
        assert url == "https://my-mac.ts.net:9443"
        assert tailscale_called["called"] is False

    def test_tailscale_serve_used_when_connection_json_absent(self, monkeypatch):
        """Falls through to Tailscale Serve when Desktop discovery returns None."""
        monkeypatch.setattr(
            mobile_pair, "_detect_local_desktop_gateway", lambda path=None: None
        )
        monkeypatch.setattr(
            mobile_pair,
            "_tailscale_serve_status",
            lambda: {
                "Web": {
                    "mymac.ts.net:443": {
                        "Handlers": {
                            "/": {"Proxy": "http://127.0.0.1:9119"}
                        }
                    }
                }
            },
        )
        url = mobile_pair._detect_dashboard_url()
        assert url == "https://mymac.ts.net:443"

    def test_both_absent_returns_none(self, monkeypatch):
        monkeypatch.setattr(
            mobile_pair, "_detect_local_desktop_gateway", lambda path=None: None
        )
        monkeypatch.setattr(mobile_pair, "_tailscale_serve_status", lambda: None)
        assert mobile_pair._detect_dashboard_url() is None

    def test_local_mode_probe_url_returned_by_detect_dashboard_url(self, monkeypatch):
        """Local mode's probe URL is returned as the dashboard URL."""
        monkeypatch.setattr(
            mobile_pair,
            "_detect_local_desktop_gateway",
            lambda path=None: mobile_pair._DesktopGatewayResult(
                url="http://127.0.0.1:9131",
                token=None,
                manual_token=True,
                source="loopback probe :9131",
            ),
        )
        url = mobile_pair._detect_dashboard_url()
        assert url == "http://127.0.0.1:9131"
