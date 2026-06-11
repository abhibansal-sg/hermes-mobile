"""W3A-S — QR payload v2 (mobile-pair --device-token). v2 is ADDITIVE +
BACKWARD-COMPATIBLE: ``token`` stays the credential key in BOTH versions so a
v1 parser never breaks; ``kind``/``device_id`` are extra keys a v1 app ignores.
"""

from __future__ import annotations

from types import SimpleNamespace
from urllib.parse import urlparse, parse_qs

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module

mobile_pair = load_plugin_module("mobile_pair")


# ===========================================================================
# Link building — v1 unchanged, v2 additive
# ===========================================================================


def test_v1_link_unchanged():
    link = mobile_pair._build_pair_link("https://h.ts.net:9119", "SHARED")
    q = parse_qs(urlparse(link).query)
    assert link.startswith("hermesapp://pair?")
    assert q["url"] == ["https://h.ts.net:9119"]
    assert q["token"] == ["SHARED"]
    assert "kind" not in q and "device_id" not in q


def test_v2_link_adds_kind_and_device_id_keeping_token_key():
    link = mobile_pair._build_pair_link(
        "https://h.ts.net:9119", "DEVICETOK", kind="device", device_id="dev_xyz"
    )
    q = parse_qs(urlparse(link).query)
    # ``token`` is STILL the credential key (a v1 parser pairs on it unchanged).
    assert q["token"] == ["DEVICETOK"]
    assert q["kind"] == ["device"]
    assert q["device_id"] == ["dev_xyz"]


def test_v2_keys_omitted_without_both_kind_and_device_id():
    # Defensive: kind without device_id (or vice versa) → v1 shape, no partial v2.
    only_kind = mobile_pair._build_pair_link("u", "t", kind="device")
    assert "kind" not in parse_qs(urlparse(only_kind).query)
    only_id = mobile_pair._build_pair_link("u", "t", device_id="dev_1")
    assert "device_id" not in parse_qs(urlparse(only_id).query)


def test_device_id_is_percent_encoded():
    link = mobile_pair._build_pair_link(
        "u", "t", kind="device", device_id="dev_a/b c"
    )
    q = parse_qs(urlparse(link).query)
    assert q["device_id"] == ["dev_a/b c"]  # round-trips through encode/decode


# ===========================================================================
# _issue_device_token — mocked HTTP
# ===========================================================================


class _FakeResp:
    def __init__(self, status, payload):
        self.status = status
        self._payload = payload

    def read(self):
        import json

        return json.dumps(self._payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_issue_device_token_success(monkeypatch):
    captured = {}

    def _fake_urlopen(req, timeout=0):
        captured["url"] = req.full_url
        captured["method"] = req.get_method()
        captured["token_header"] = req.headers.get("X-hermes-session-token")
        captured["host_header"] = req.headers.get("Host")
        return _FakeResp(200, {"device_id": "dev_1", "token": "DEVTOK", "device_name": "x"})

    monkeypatch.setattr("urllib.request.urlopen", _fake_urlopen)
    out = mobile_pair._issue_device_token("https://h.ts.net:9119", "SHARED")
    assert out["device_id"] == "dev_1"
    assert out["token"] == "DEVTOK"
    # Canonical post-de-patch route is the plugin mount (tried first).
    assert captured["url"].endswith("/api/plugins/hermes-mobile/devices/issue")
    assert captured["method"] == "POST"
    assert captured["token_header"] == "SHARED"
    assert captured["host_header"] == "127.0.0.1"


def test_issue_device_token_falls_back_to_legacy_path(monkeypatch):
    """A pre-de-patch server 404s the plugin route; the legacy top-level
    /api/devices/issue must be tried next so pairing keeps working."""
    calls = []

    def _fake_urlopen(req, timeout=0):
        calls.append(req.full_url)
        if "/api/plugins/hermes-mobile/" in req.full_url:
            import urllib.error

            raise urllib.error.HTTPError(req.full_url, 404, "nf", {}, None)
        return _FakeResp(200, {"device_id": "dev_1", "token": "DEVTOK"})

    monkeypatch.setattr("urllib.request.urlopen", _fake_urlopen)
    out = mobile_pair._issue_device_token("https://h.ts.net:9119", "SHARED")
    assert out["token"] == "DEVTOK"
    assert calls[0].endswith("/api/plugins/hermes-mobile/devices/issue")
    assert calls[1].endswith("/api/devices/issue")


def test_issue_device_token_non_200_returns_none(monkeypatch):
    monkeypatch.setattr(
        "urllib.request.urlopen", lambda req, timeout=0: _FakeResp(404, {})
    )
    assert mobile_pair._issue_device_token("https://h", "SHARED") is None


def test_issue_device_token_network_error_returns_none(monkeypatch):
    import urllib.error

    def _boom(req, timeout=0):
        raise urllib.error.URLError("nope")

    monkeypatch.setattr("urllib.request.urlopen", _boom)
    assert mobile_pair._issue_device_token("https://h", "SHARED") is None


def test_issue_device_token_missing_fields_returns_none(monkeypatch):
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda req, timeout=0: _FakeResp(200, {"device_id": "dev_1"}),  # no token
    )
    assert mobile_pair._issue_device_token("https://h", "SHARED") is None


# ===========================================================================
# mobile_pair_command — default v2, explicit legacy flag emits v1
# ===========================================================================


@pytest.fixture
def stub_env(monkeypatch):
    monkeypatch.setattr(mobile_pair, "_detect_dashboard_url", lambda: "https://h.ts.net:9119")
    monkeypatch.setattr(mobile_pair, "_read_dashboard_token", lambda: "SHARED")
    monkeypatch.setattr(mobile_pair, "_render_ansi_qr", lambda payload: None)


def test_command_default_mints_and_emits_v2(stub_env, monkeypatch, capsys):
    monkeypatch.setattr(
        mobile_pair, "_issue_device_token",
        lambda url, tok: {"token": "DEVTOK", "device_id": "dev_abc"},
    )
    args = SimpleNamespace(url=None)
    rc = mobile_pair.mobile_pair_command(args)
    assert rc == 0
    out = capsys.readouterr().out
    assert "token=DEVTOK" in out
    assert "kind=device" in out
    assert "device_id=dev_abc" in out
    assert "token=SHARED" not in out
    assert "--tui" in out
    assert "HERMES_DASHBOARD_TUI=1" in out


def test_command_shared_token_legacy_path_no_issue_call(stub_env, monkeypatch, capsys):
    called = {"issue": False}
    monkeypatch.setattr(
        mobile_pair, "_issue_device_token",
        lambda *a, **k: (called.__setitem__("issue", True) or {"token": "x", "device_id": "y"}),
    )
    args = SimpleNamespace(url=None, device_token=False)
    rc = mobile_pair.mobile_pair_command(args)
    assert rc == 0
    assert called["issue"] is False
    out = capsys.readouterr().out
    assert "token=SHARED" in out
    assert "kind=device" not in out


def test_command_device_token_issue_failure_returns_1(stub_env, monkeypatch, capsys):
    monkeypatch.setattr(mobile_pair, "_issue_device_token", lambda url, tok: None)
    args = SimpleNamespace(url=None)
    rc = mobile_pair.mobile_pair_command(args)
    assert rc == 1
    assert "--shared-token" in capsys.readouterr().out


def test_read_dashboard_token_uses_active_hermes_home(tmp_path, monkeypatch):
    home = tmp_path / "profile"
    home.mkdir()
    (home / "dashboard.token").write_text("PROFILE_TOKEN\n", encoding="utf-8")
    monkeypatch.delenv("HERMES_DASHBOARD_SESSION_TOKEN", raising=False)
    monkeypatch.setenv("HERMES_HOME", str(home))

    assert mobile_pair._read_dashboard_token() == "PROFILE_TOKEN"
