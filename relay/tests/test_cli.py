"""CLI / config-resolution tests for ``python -m hermes_relay``.

Hermetic: exercises :func:`hermes_relay.__main__.resolve_config` purely (no
sockets, no asyncio). Verifies the CLI > env > default precedence, ws-URL and
host:port parsing, the health toggles, token sourcing, and the hard refusal of
the live gateway port.
"""

from __future__ import annotations

import pytest

from hermes_relay.__main__ import (
    LIVE_GATEWAY_PORT,
    _to_relay_config,
    resolve_config,
)


@pytest.fixture(autouse=True)
def _clear_env(monkeypatch):
    for k in (
        "HERMES_RELAY_GATEWAY_TOKEN",
        "HERMES_RELAY_GATEWAY_URL",
        "HERMES_RELAY_GATEWAY_HOST",
        "HERMES_RELAY_GATEWAY_PORT",
        "HERMES_RELAY_DOWNSTREAM_HOST",
        "HERMES_RELAY_DOWNSTREAM_PORT",
        "HERMES_RELAY_HEALTH_PATH",
        "HERMES_RELAY_LOG_LEVEL",
    ):
        monkeypatch.delenv(k, raising=False)


def test_defaults_with_env_token(monkeypatch):
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "envtok")
    rc = resolve_config([])
    assert rc.token == "envtok"
    assert (rc.gateway_host, rc.gateway_port) == ("127.0.0.1", 9126)
    assert (rc.downstream_host, rc.downstream_port) == ("127.0.0.1", 8765)
    assert rc.health_path == "/healthz"


def test_cli_overrides_env(monkeypatch):
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "envtok")
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_PORT", "9126")
    monkeypatch.setenv("HERMES_RELAY_DOWNSTREAM_PORT", "8765")
    rc = resolve_config(
        ["--gateway-port", "9130", "--listen", "0.0.0.0:8790", "--token", "clitok"]
    )
    assert rc.token == "clitok"  # CLI token beats env token
    assert rc.gateway_port == 9130  # CLI port beats env port
    assert (rc.downstream_host, rc.downstream_port) == ("0.0.0.0", 8790)


def test_gateway_url_is_parsed(monkeypatch):
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "t")
    rc = resolve_config(["--gateway-url", "ws://10.0.0.2:9200/api/ws"])
    assert (rc.gateway_host, rc.gateway_port) == ("10.0.0.2", 9200)


def test_gateway_url_from_env(monkeypatch):
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "t")
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_URL", "ws://gw.local:9201")
    rc = resolve_config([])
    assert (rc.gateway_host, rc.gateway_port) == ("gw.local", 9201)


def test_listen_bare_port(monkeypatch):
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "t")
    rc = resolve_config(["--listen", "8801"])
    assert rc.downstream_port == 8801
    assert rc.downstream_host == "127.0.0.1"  # host falls back to default


def test_live_gateway_port_is_refused(monkeypatch):
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "t")
    with pytest.raises(SystemExit) as ei:
        resolve_config(["--gateway-port", str(LIVE_GATEWAY_PORT)])
    assert str(LIVE_GATEWAY_PORT) in str(ei.value)


def test_live_gateway_port_refused_via_url(monkeypatch):
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "t")
    with pytest.raises(SystemExit):
        resolve_config(["--gateway-url", f"ws://127.0.0.1:{LIVE_GATEWAY_PORT}"])


def test_missing_token_raises(monkeypatch):
    with pytest.raises(SystemExit):
        resolve_config([])


def test_token_file_is_read(tmp_path, monkeypatch):
    f = tmp_path / "tok"
    f.write_text("filetok\n")
    rc = resolve_config(["--token-file", str(f)])
    assert rc.token == "filetok"


def test_no_health_disables_surface(monkeypatch):
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "t")
    rc = resolve_config(["--no-health"])
    assert rc.health_path is None


def test_custom_health_path(monkeypatch):
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "t")
    rc = resolve_config(["--health-path", "/status"])
    assert rc.health_path == "/status"


def test_resolved_config_builds_relay_config(monkeypatch):
    """The resolved CLI config threads through into a valid RelayConfig."""
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "t")
    rc = resolve_config(["--gateway-port", "9131", "--listen", "127.0.0.1:8802"])
    cfg = _to_relay_config(rc)
    assert cfg.gateway.port == 9131
    assert cfg.gateway.token == "t"
    assert cfg.downstream.port == 8802
    assert cfg.downstream.health_path == "/healthz"
