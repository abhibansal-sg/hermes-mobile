"""CLI / config-resolution tests for ``python -m hermes_relay``.

Hermetic: exercises :func:`hermes_relay.__main__.resolve_config` purely (no
sockets, no asyncio). Verifies the CLI > env > default precedence, ws-URL and
host:port parsing, the health toggles, token sourcing, and the live-gateway
gate: port 9119 is refused by default (with a refusal message that names the
escape hatch) and accepted ONLY with the explicit ``--allow-live-gateway``
flag that the supervised launchd service (spec N6/A7) passes.
"""

from __future__ import annotations

import plistlib
from pathlib import Path

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


def test_live_gateway_refusal_message_names_the_flag(monkeypatch):
    """The refusal must tell operators about the supervised-service escape hatch."""
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "t")
    with pytest.raises(SystemExit) as ei:
        resolve_config(["--gateway-port", str(LIVE_GATEWAY_PORT)])
    msg = str(ei.value)
    assert str(LIVE_GATEWAY_PORT) in msg
    assert "--allow-live-gateway" in msg
    assert "install-service.sh" in msg  # points at the sanctioned path


def test_live_gateway_accepted_with_flag(monkeypatch):
    """--allow-live-gateway lifts the 9119 refusal (service mode only)."""
    rc = resolve_config(
        [
            "--gateway-host",
            "127.0.0.1",
            "--gateway-port",
            str(LIVE_GATEWAY_PORT),
            "--allow-live-gateway",
            "--listen",
            "0.0.0.0:8788",
            "--token",
            "t",
        ]
    )
    assert rc.gateway_port == LIVE_GATEWAY_PORT
    assert rc.allow_live_gateway is True
    assert (rc.downstream_host, rc.downstream_port) == ("0.0.0.0", 8788)


def test_live_gateway_accepted_with_flag_via_url(monkeypatch):
    rc = resolve_config(
        [
            "--gateway-url",
            f"ws://127.0.0.1:{LIVE_GATEWAY_PORT}",
            "--allow-live-gateway",
            "--token",
            "t",
        ]
    )
    assert rc.gateway_port == LIVE_GATEWAY_PORT
    assert rc.allow_live_gateway is True


def test_allow_live_gateway_defaults_off(monkeypatch):
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "t")
    rc = resolve_config([])
    assert rc.allow_live_gateway is False


def test_allow_live_gateway_harmless_on_isolated_port(monkeypatch):
    """The flag only lifts the gate; it changes nothing on 9126+."""
    monkeypatch.setenv("HERMES_RELAY_GATEWAY_TOKEN", "t")
    rc = resolve_config(["--gateway-port", "9130", "--allow-live-gateway"])
    assert rc.gateway_port == 9130
    assert rc.allow_live_gateway is True


def test_service_shape_resolves_to_relay_config(monkeypatch):
    """The exact shape the ai.hermes.relay plist runs resolves to a RelayConfig."""
    rc = resolve_config(
        [
            "--gateway-host",
            "127.0.0.1",
            "--gateway-port",
            str(LIVE_GATEWAY_PORT),
            "--allow-live-gateway",
            "--listen",
            "0.0.0.0:8788",
            "--token",
            "dashboard",
        ]
    )
    cfg = _to_relay_config(rc)
    assert cfg.gateway.host == "127.0.0.1"
    assert cfg.gateway.port == LIVE_GATEWAY_PORT
    assert cfg.gateway.token == "dashboard"
    assert cfg.downstream.host == "0.0.0.0"
    assert cfg.downstream.port == 8788
    assert cfg.downstream.auth_token == "dashboard"


def test_service_exposes_stock_runtime_and_plugin_paths():
    template = (
        Path(__file__).parents[1] / "scripts" / "ai.hermes.relay.plist"
    ).read_bytes()
    environment = plistlib.loads(template)["EnvironmentVariables"]
    assert environment["PYTHONPATH"] == "__HERMES_HOME__/hermes-agent"
    assert (
        environment["HERMES_RELAY_PLUGIN_DIR"]
        == "__HERMES_HOME__/plugins/hermes-mobile"
    )


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


def _stub_app_run(monkeypatch):
    """Make main() hermetic: no RelayApp construction, no asyncio.run."""
    import hermes_relay.__main__ as entry

    built = []

    class _FakeApp:
        def __init__(self, cfg):
            built.append(cfg)

        async def run(self):
            pass

    monkeypatch.setattr(entry, "RelayApp", _FakeApp)
    monkeypatch.setattr(entry.asyncio, "run", lambda coro: coro.close())
    return built


def test_main_warns_when_dialing_live_gateway(monkeypatch, caplog):
    """Service mode (9119 + flag) boots, but logs a WARNING that it did so."""
    import logging

    _stub_app_run(monkeypatch)
    with caplog.at_level(logging.WARNING, logger="hermes_relay"):
        from hermes_relay.__main__ import main

        main(
            [
                "--gateway-port",
                str(LIVE_GATEWAY_PORT),
                "--allow-live-gateway",
                "--token",
                "t",
            ]
        )
    assert any(
        rec.levelno == logging.WARNING and str(LIVE_GATEWAY_PORT) in rec.getMessage()
        for rec in caplog.records
    )


def test_main_no_warning_on_isolated_gateway(monkeypatch, caplog):
    import logging

    _stub_app_run(monkeypatch)
    with caplog.at_level(logging.WARNING, logger="hermes_relay"):
        from hermes_relay.__main__ import main

        main(["--gateway-port", "9132", "--token", "t"])
    assert not any(
        rec.levelno == logging.WARNING and "LIVE gateway" in rec.getMessage()
        for rec in caplog.records
    )
