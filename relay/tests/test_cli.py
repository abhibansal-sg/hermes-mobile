"""CLI / config-resolution tests for ``python -m hermes_relay``.

Hermetic: exercises :func:`hermes_relay.__main__.resolve_config` purely (no
sockets, no asyncio). Verifies the CLI > env > default precedence, ws-URL and
host:port parsing, the health toggles, token sourcing, and the hard refusal of
the live gateway port.
"""

from __future__ import annotations

import json
import os

import pytest

from hermes_relay.__main__ import (
    LIVE_GATEWAY_PORT,
    RelayRuntimeAlreadyRunning,
    _RelayRuntimeLock,
    _to_relay_config,
    _write_runtime_readiness,
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


def test_v2_defaults_to_real_loopback_gateway_and_requires_token_file(tmp_path):
    token_file = tmp_path / "gateway.token"
    token_file.write_text("file-only-token", encoding="utf-8")
    token_file.chmod(0o600)
    rc = resolve_config(
        [
            "--protocol",
            "v2",
            "--token-file",
            str(token_file),
            "--hub-url",
            "https://hub.example.test",
            "--no-push",
        ]
    )
    assert rc.gateway_host == "127.0.0.1"
    assert rc.gateway_port == LIVE_GATEWAY_PORT
    assert rc.token == "file-only-token"


def test_v2_rejects_non_loopback_gateway(tmp_path):
    token_file = tmp_path / "gateway.token"
    token_file.write_text("file-only-token", encoding="utf-8")
    token_file.chmod(0o600)
    with pytest.raises(SystemExit, match="loopback Gateway"):
        resolve_config(
            [
                "--protocol",
                "v2",
                "--gateway-host",
                "gateway.example.test",
                "--token-file",
                str(token_file),
                "--hub-url",
                "https://hub.example.test",
                "--no-push",
            ]
        )


def test_v2_managed_readiness_path_is_exact_and_never_accepts_database(
    tmp_path,
):
    token_file = tmp_path / "gateway.token"
    token_file.write_text("file-only-token", encoding="utf-8")
    token_file.chmod(0o600)
    state = tmp_path / "state"
    state.mkdir()
    common = [
        "--protocol",
        "v2",
        "--token-file",
        str(token_file),
        "--hub-url",
        "https://hub.example.test",
        "--no-push",
        "--state-dir",
        str(state),
        "--launch-nonce",
        "n" * 32,
    ]
    rc = resolve_config(
        [*common, "--ready-file", str(state / "readiness.json")]
    )
    assert rc.ready_file == str(state / "readiness.json")
    with pytest.raises(SystemExit, match="reserved readiness file"):
        resolve_config([*common, "--ready-file", str(state / "relay.sqlite3")])


def test_runtime_readiness_file_is_atomic_owner_only_and_content_free(tmp_path):
    marker = tmp_path / "readiness.json"
    _write_runtime_readiness(
        marker,
        launch_nonce="n" * 32,
        route_id="rte_agent",
    )
    payload = json.loads(marker.read_text(encoding="utf-8"))
    assert payload["launch_nonce"] == "n" * 32
    assert payload["route_id"] == "rte_agent"
    assert set(payload) == {
        "v",
        "pid",
        "launch_nonce",
        "written_at_ms",
        "route_id",
    }
    assert marker.stat().st_mode & 0o077 == 0
    assert list(tmp_path.glob("*.tmp")) == []


def test_runtime_lock_rejects_contention_and_releases(tmp_path):
    first = _RelayRuntimeLock(tmp_path)
    first.__enter__()
    try:
        with pytest.raises(RelayRuntimeAlreadyRunning):
            with _RelayRuntimeLock(tmp_path):
                pass
    finally:
        first.__exit__(None, None, None)
    with _RelayRuntimeLock(tmp_path):
        pass


@pytest.mark.skipif(os.name != "posix", reason="requires POSIX symlinks")
def test_runtime_lock_canonicalizes_symlink_aliases(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    alias = tmp_path / "alias"
    alias.symlink_to(state, target_is_directory=True)

    with _RelayRuntimeLock(state) as first:
        assert first.path.parent == state.parent
        assert first.path.parent != state
        with pytest.raises(RelayRuntimeAlreadyRunning):
            with _RelayRuntimeLock(alias):
                pass


@pytest.mark.skipif(os.name != "posix", reason="requires POSIX no-follow opens")
def test_runtime_lock_refuses_symlink_and_hardlink_targets(tmp_path):
    state = tmp_path / "state"
    victim = tmp_path / "victim"
    victim.write_bytes(b"unchanged")
    lock_path = tmp_path / ".state.runtime.lock"
    lock_path.symlink_to(victim)
    with pytest.raises(RelayRuntimeAlreadyRunning):
        with _RelayRuntimeLock(state):
            pass
    assert victim.read_bytes() == b"unchanged"
    lock_path.unlink()
    os.link(victim, lock_path)
    with pytest.raises(RelayRuntimeAlreadyRunning):
        with _RelayRuntimeLock(state):
            pass
    assert victim.read_bytes() == b"unchanged"


@pytest.mark.skipif(os.name != "posix", reason="requires POSIX no-follow opens")
def test_v2_token_file_refuses_symlinks_and_hardlinks(tmp_path):
    token = tmp_path / "token"
    token.write_text("secret", encoding="utf-8")
    token.chmod(0o600)
    symlink = tmp_path / "token-link"
    symlink.symlink_to(token)
    common = [
        "--protocol",
        "v2",
        "--hub-url",
        "https://hub.example.test",
        "--no-push",
    ]
    with pytest.raises(SystemExit, match="cannot read --token-file"):
        resolve_config([*common, "--token-file", str(symlink)])
    hardlink = tmp_path / "token-hardlink"
    os.link(token, hardlink)
    with pytest.raises(SystemExit, match="cannot read --token-file"):
        resolve_config([*common, "--token-file", str(hardlink)])


@pytest.mark.parametrize(
    "option,url",
    [
        ("--hub-url", "https://user:secret@hub.example.test"),
        ("--hub-url", "https://hub.example.test/base"),
        ("--hub-url", "https://hub.example.test?secret=value"),
        ("--push-url", "https://push.example.test#secret"),
    ],
)
def test_v2_service_urls_are_origin_only(tmp_path, option, url):
    token = tmp_path / "gateway.token"
    token.write_text("secret", encoding="utf-8")
    token.chmod(0o600)
    arguments = [
        "--protocol",
        "v2",
        "--token-file",
        str(token),
        "--hub-url",
        "https://hub.example.test",
        "--push-url",
        "https://push.example.test",
    ]
    index = arguments.index(option)
    arguments[index + 1] = url
    with pytest.raises(SystemExit, match="must not contain"):
        resolve_config(arguments)


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
