"""Behavior contracts for the plugin-owned ``hermes mobile`` surface."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sqlite3
import sys
import time
import types
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module


def _module():
    return load_plugin_module("mobile_relay_cli")


def _settings(module, tmp_path: Path):
    token = tmp_path / "dashboard.token"
    token.write_text("gateway-secret", encoding="utf-8")
    token.chmod(0o600)
    return module.MobileSettings(
        hermes_home=tmp_path,
        enabled=False,
        hub_url="https://hub.example.test",
        push_enabled=True,
        push_url="https://push.example.test",
        preview_policy="after_first_unlock",
        mailbox_ttl_seconds=86400,
        log_level="info",
        gateway_host="127.0.0.1",
        gateway_port=9126,
        gateway_token_file=token,
        state_directory=tmp_path / "mobile-relay",
        service_system=False,
        allow_insecure_local_services=False,
        hub_enrollment_token_file=None,
    )


def _enable_args(**overrides):
    values = {
        "hub": None,
        "push_url": None,
        "no_push": False,
        "system": False,
        "gateway_host": None,
        "gateway_port": None,
        "token_file": None,
        "allow_insecure_local_services": False,
        "hub_enrollment_token_file": None,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def test_parser_exposes_the_ratified_operator_commands():
    module = _module()
    parser = argparse.ArgumentParser()
    module.register_cli(parser)
    for argv, action in (
        (["enable", "--hub", "https://hub.test"], "enable"),
        (["relay", "run"], "relay"),
        (["status", "--json"], "status"),
        (["pair", "--ttl", "300"], "pair"),
        (["devices"], "devices"),
        (["revoke", "dev_1"], "revoke"),
        (["logs", "--follow"], "logs"),
        (["disable", "--purge", "--yes"], "disable"),
    ):
        assert parser.parse_args(argv).mobile_action == action


def test_enable_rejects_conflicting_push_modes():
    module = _module()
    parser = argparse.ArgumentParser()
    module.register_cli(parser)
    with pytest.raises(SystemExit):
        parser.parse_args(
            [
                "enable",
                "--hub",
                "https://hub.test",
                "--push-url",
                "https://push.test",
                "--no-push",
            ]
        )


def test_service_spec_contains_paths_but_no_gateway_secret(tmp_path, monkeypatch):
    module = _module()
    settings = _settings(module, tmp_path)
    operator_file = tmp_path / "operator.token"
    operator_file.write_text("operator-secret", encoding="utf-8")
    operator_file.chmod(0o600)
    settings = replace(settings, hub_enrollment_token_file=operator_file)
    relay_root = tmp_path / "relay"
    relay_root.mkdir()
    manager = object()
    monkeypatch.setattr(module, "_ensure_relay_runtime", lambda: relay_root)
    monkeypatch.setattr(module, "_service_name", lambda _home: "hermes-mobile-relay-test")
    import hermes_cli.service_manager as service_manager

    monkeypatch.setattr(service_manager, "get_service_manager", lambda: manager)
    returned, spec = module._service_manager_and_spec(
        settings, launch_nonce="n" * 32
    )
    assert returned is manager
    assert "gateway-secret" not in repr(spec)
    assert "operator-secret" not in repr(spec)
    assert "--token-file" in spec.command
    assert str(settings.gateway_token_file) in spec.command
    assert "--ready-file" in spec.command
    assert str(settings.state_directory / "readiness.json") in spec.command
    assert "--launch-nonce" in spec.command
    assert "n" * 32 in spec.command
    assert spec.environment == {"HERMES_HOME": str(tmp_path)}


def test_foreground_relay_publishes_managed_format_readiness(tmp_path, monkeypatch):
    module = _module()
    settings = _settings(module, tmp_path)
    captured = []
    import hermes_relay.__main__ as relay_entrypoint

    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_validate_settings", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(module, "_ensure_relay_runtime", lambda: tmp_path)
    monkeypatch.setattr(relay_entrypoint, "main", captured.append)

    assert module._cmd_relay_run(argparse.Namespace()) == 0
    argv = captured[0]
    ready_index = argv.index("--ready-file")
    nonce_index = argv.index("--launch-nonce")
    assert argv[ready_index + 1] == str(settings.state_directory / "readiness.json")
    assert len(argv[nonce_index + 1]) >= 32


def test_config_persists_operator_token_path_never_token_value(tmp_path, monkeypatch):
    module = _module()
    operator_file = tmp_path / "operator.token"
    operator_file.write_text("operator-secret", encoding="utf-8")
    operator_file.chmod(0o600)
    settings = replace(
        _settings(module, tmp_path), hub_enrollment_token_file=operator_file
    )
    captured: dict = {}
    import hermes_cli.config as config

    monkeypatch.setattr(config, "is_managed", lambda: False)
    monkeypatch.setattr(config, "read_raw_config", lambda: {})
    monkeypatch.setattr(
        config,
        "save_config",
        lambda value, **_kwargs: captured.update(value),
    )
    monkeypatch.setattr(module, "_legacy_relay_url", lambda _home: None)
    module._write_settings(settings)
    assert captured["mobile"]["hub_enrollment_token_file"] == str(operator_file)
    assert "operator-secret" not in repr(captured)


def test_enable_is_repeatable_and_bootstraps_before_install(tmp_path, monkeypatch):
    module = _module()
    settings = _settings(module, tmp_path)
    calls: list[str] = []

    class Manager:
        installed = False

        def is_service_installed(self, _name, *, system=False):
            return self.installed

        def install_service(self, _spec, *, system=False, start_now=True):
            calls.append("install")
            self.installed = True

        def is_service_running(self, _name, *, system=False):
            return self.installed

        def uninstall_service(self, _name, *, system=False):
            calls.append("uninstall")
            self.installed = False

    manager = Manager()
    spec = SimpleNamespace(name="hermes-mobile-relay-test")
    def bootstrap_effect(_settings):
        calls.append("bootstrap")
        return "provisional"

    bootstrap = AsyncMock(side_effect=bootstrap_effect)
    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_bootstrap_route", bootstrap)
    monkeypatch.setattr(
        module, "_relay_state_ready", lambda _settings, **_kwargs: True
    )
    monkeypatch.setattr(module, "_write_settings", lambda _settings: calls.append("config"))
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda _settings, **_kwargs: (manager, spec),
    )

    args = _enable_args()
    assert module._cmd_enable(args) == 0
    assert module._cmd_enable(args) == 0
    assert calls == ["bootstrap", "config", "install", "bootstrap", "config", "install"]


def test_repeat_enable_preserves_no_push_and_system_service(tmp_path, monkeypatch):
    module = _module()
    settings = replace(
        _settings(module, tmp_path),
        enabled=True,
        push_enabled=False,
        push_url=None,
        service_system=True,
    )
    captured = []

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            assert system is True
            return True

        def install_service(self, _spec, *, system=False, start_now=True):
            assert system is True

        def is_service_running(self, _name, *, system=False):
            assert system is True
            return True

    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_operator_activation_required", lambda _settings: False)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_bootstrap_route", AsyncMock(return_value="active"))
    monkeypatch.setattr(
        module, "_relay_state_ready", lambda _settings, **_kwargs: True
    )
    monkeypatch.setattr(module, "_write_settings", captured.append)
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
            lambda _settings, **_kwargs: (
                Manager(),
                SimpleNamespace(name="relay-test"),
            ),
    )
    args = _enable_args()

    assert module._cmd_enable(args) == 0
    assert captured[0].push_enabled is False
    assert captured[0].push_url is None
    assert captured[0].service_system is True


def test_plain_reenable_preserves_disabled_no_push_preference(tmp_path, monkeypatch):
    module = _module()
    settings = replace(
        _settings(module, tmp_path),
        enabled=False,
        push_enabled=False,
        push_url=None,
        hub_enrollment_token_file=tmp_path / "operator.token",
    )
    settings.hub_enrollment_token_file.write_text("operator", encoding="utf-8")
    settings.hub_enrollment_token_file.chmod(0o600)
    captured = []

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return False

        def install_service(self, _spec, *, system=False, start_now=True):
            return None

        def is_service_running(self, _name, *, system=False):
            return True

        def uninstall_service(self, _name, *, system=False):
            raise AssertionError("successful re-enable must not roll back")

    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_operator_activation_required", lambda _value: False)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_bootstrap_route", AsyncMock(return_value="active"))
    monkeypatch.setattr(module, "_relay_state_ready", lambda *_args, **_kwargs: True)
    monkeypatch.setattr(module, "_write_settings", captured.append)
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda _value, **_kwargs: (Manager(), SimpleNamespace(name="relay-test")),
    )

    assert module._cmd_enable(_enable_args()) == 0
    assert captured == [replace(settings, enabled=True)]


def test_startup_readiness_failure_removes_only_new_service_artifacts(
    tmp_path, monkeypatch
):
    module = _module()
    settings = replace(
        _settings(module, tmp_path),
        enabled=False,
        hub_url="https://old-hub.example.test",
        push_enabled=False,
        push_url=None,
    )
    calls: list[str] = []
    written = []

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return False

        def install_service(self, _spec, *, system=False, start_now=True):
            calls.append("install")

        def uninstall_service(self, _name, *, system=False):
            calls.append("rollback-uninstall")

    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_bootstrap_route", AsyncMock(return_value="active"))
    monkeypatch.setattr(module, "_write_settings", written.append)
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda _settings, **_kwargs: (Manager(), SimpleNamespace(name="relay-new")),
    )
    monkeypatch.setattr(module, "_wait_for_service", lambda *_args, **_kwargs: False)

    with pytest.raises(module.MobileRelayCLIError, match="did not reach ready state"):
        module._cmd_enable(
            _enable_args(
                hub="https://new-hub.example.test",
                push_url="https://new-push.example.test",
            )
        )

    assert calls == ["install", "rollback-uninstall"]
    assert written == [
        replace(
            settings,
            enabled=True,
            hub_url="https://new-hub.example.test",
            push_enabled=True,
            push_url="https://new-push.example.test",
        ),
        settings,
    ]


def test_partial_install_exception_rolls_back_new_service_artifact(
    tmp_path, monkeypatch
):
    module = _module()
    settings = replace(
        _settings(module, tmp_path),
        enabled=False,
        hub_url="https://old-hub.example.test",
        push_enabled=False,
        push_url=None,
    )
    calls: list[str] = []
    written = []

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return False

        def install_service(self, _spec, *, system=False, start_now=True):
            calls.append("partial-install")
            raise OSError("simulated supervisor write failure")

        def uninstall_service(self, _name, *, system=False):
            calls.append("rollback-uninstall")

    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_bootstrap_route", AsyncMock(return_value="active"))
    monkeypatch.setattr(module, "_write_settings", written.append)
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda _settings, **_kwargs: (
            Manager(),
            SimpleNamespace(name="relay-partial"),
        ),
    )

    with pytest.raises(OSError, match="supervisor write failure"):
        module._cmd_enable(
            _enable_args(
                hub="https://new-hub.example.test",
                push_url="https://new-push.example.test",
            )
        )

    assert calls == ["partial-install", "rollback-uninstall"]
    assert written == [
        replace(
            settings,
            enabled=True,
            hub_url="https://new-hub.example.test",
            push_enabled=True,
            push_url="https://new-push.example.test",
        ),
        settings,
    ]


def test_existing_service_reconfigure_failure_restores_prior_config_and_spec(
    tmp_path, monkeypatch
):
    module = _module()
    settings = replace(
        _settings(module, tmp_path),
        enabled=True,
        hub_url="https://old-hub.example.test",
        push_enabled=True,
        push_url="https://old-push.example.test",
    )
    written = []
    installed_specs = []

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return True

        def install_service(self, spec, *, system=False, start_now=True):
            installed_specs.append(spec.settings)

        def uninstall_service(self, _name, *, system=False):
            raise AssertionError("preexisting service must not be removed")

    manager = Manager()
    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_bootstrap_route", AsyncMock(return_value="active"))
    monkeypatch.setattr(module, "_write_settings", written.append)
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda value, **_kwargs: (
            manager,
            SimpleNamespace(name="relay-existing", settings=value),
        ),
    )
    monkeypatch.setattr(module, "_wait_for_service", lambda *_args, **_kwargs: False)

    with pytest.raises(module.MobileRelayCLIError, match="did not reach ready state"):
        module._cmd_enable(
            _enable_args(
                hub="https://new-hub.example.test",
                push_url="https://new-push.example.test",
            )
        )

    expected_attempt = replace(
        settings,
        hub_url="https://new-hub.example.test",
        push_url="https://new-push.example.test",
    )
    assert written == [expected_attempt, settings]
    assert installed_specs == [expected_attempt, settings]


def test_user_to_system_transition_retires_old_scope_before_start(
    tmp_path, monkeypatch
):
    module = _module()
    current = replace(_settings(module, tmp_path), enabled=True, service_system=False)
    calls = []
    installed = {False: True, True: False}
    running = {False: True, True: False}

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return installed[system]

        def is_service_running(self, _name, *, system=False):
            return running[system]

        def stop_service(self, _name, *, system=False):
            calls.append(("stop", system))
            running[system] = False

        def uninstall_service(self, _name, *, system=False):
            calls.append(("uninstall", system))
            installed[system] = False
            running[system] = False

        def install_service(self, spec, *, system=False, start_now=True):
            calls.append(("install", system, spec.settings.service_system))
            installed[system] = True
            running[system] = True

    manager = Manager()
    monkeypatch.setattr(module, "_settings", lambda: current)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_bootstrap_route", AsyncMock(return_value="active"))
    monkeypatch.setattr(
        module, "_relay_state_ready", lambda _settings, **_kwargs: True
    )
    monkeypatch.setattr(module, "_write_settings", lambda _settings: None)
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda value, **_kwargs: (
            manager,
            SimpleNamespace(name="relay-scope", settings=value),
        ),
    )

    assert module._cmd_enable(_enable_args(system=True)) == 0
    assert calls == [
        ("stop", False),
        ("uninstall", False),
        ("install", True, True),
    ]
    assert installed == {False: False, True: True}
    assert running == {False: False, True: True}


def test_user_to_system_failure_restores_old_scope_and_config(
    tmp_path, monkeypatch
):
    module = _module()
    current = replace(_settings(module, tmp_path), enabled=True, service_system=False)
    calls = []
    written = []
    installed = {False: True, True: False}
    running = {False: True, True: False}

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return installed[system]

        def is_service_running(self, _name, *, system=False):
            return running[system]

        def stop_service(self, _name, *, system=False):
            calls.append(("stop", system))
            running[system] = False

        def uninstall_service(self, _name, *, system=False):
            calls.append(("uninstall", system))
            installed[system] = False
            running[system] = False

        def install_service(self, spec, *, system=False, start_now=True):
            calls.append(("install", system, spec.settings.service_system))
            installed[system] = True
            running[system] = True

    manager = Manager()
    monkeypatch.setattr(module, "_settings", lambda: current)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_bootstrap_route", AsyncMock(return_value="active"))
    monkeypatch.setattr(module, "_write_settings", written.append)
    monkeypatch.setattr(module, "_wait_for_service", lambda *_args, **_kwargs: False)
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda value, **_kwargs: (
            manager,
            SimpleNamespace(name="relay-scope", settings=value),
        ),
    )

    with pytest.raises(module.MobileRelayCLIError, match="did not reach ready"):
        module._cmd_enable(_enable_args(system=True))
    assert calls == [
        ("stop", False),
        ("uninstall", False),
        ("install", True, True),
        ("uninstall", True),
        ("install", False, False),
    ]
    assert written == [replace(current, service_system=True), current]
    assert installed == {False: True, True: False}
    assert running == {False: True, True: False}


def test_no_push_quiesces_old_service_then_cleans_before_final_config(
    tmp_path, monkeypatch
):
    module = _module()
    current = replace(_settings(module, tmp_path), enabled=True)
    current.state_directory.mkdir()
    (current.state_directory / "relay.sqlite3").write_bytes(b"state")
    running = True
    calls = []
    written = []

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return True

        def is_service_running(self, _name, *, system=False):
            return running

        def stop_service(self, _name, *, system=False):
            nonlocal running
            calls.append("stop-old")
            running = False

        def install_service(self, spec, *, system=False, start_now=True):
            nonlocal running
            assert running is False
            assert spec.settings.push_enabled is False
            calls.append("install-no-push")
            running = True

    manager = Manager()
    cleanup = AsyncMock(return_value=None)
    monkeypatch.setattr(module, "_settings", lambda: current)
    monkeypatch.setattr(module, "_operator_activation_required", lambda _settings: False)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_bootstrap_route", AsyncMock(return_value="active"))
    monkeypatch.setattr(
        module, "_relay_state_ready", lambda _settings, **_kwargs: True
    )
    monkeypatch.setattr(module, "_revoke_push_authority_for_opt_out", cleanup)
    monkeypatch.setattr(module, "_write_settings", written.append)
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda value, **_kwargs: (
            manager,
            SimpleNamespace(name="relay-opt-out", settings=value),
        ),
    )

    assert module._cmd_enable(_enable_args(no_push=True)) == 0
    assert calls == ["stop-old", "install-no-push"]
    assert written == [
        replace(current, push_enabled=False, push_url=current.push_url),
        replace(current, push_enabled=False, push_url=None),
    ]
    cleanup_settings = cleanup.await_args.args[0]
    assert cleanup_settings.push_enabled is True
    assert cleanup_settings.push_url == current.push_url


def test_failed_no_push_cleanup_stays_safely_disabled_with_retry_url(
    tmp_path, monkeypatch
):
    module = _module()
    current = replace(_settings(module, tmp_path), enabled=True)
    current.state_directory.mkdir()
    (current.state_directory / "relay.sqlite3").write_bytes(b"state")
    running = True
    installed_specs = []
    written = []

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return True

        def is_service_running(self, _name, *, system=False):
            return running

        def stop_service(self, _name, *, system=False):
            nonlocal running
            running = False

        def install_service(self, spec, *, system=False, start_now=True):
            nonlocal running
            installed_specs.append(spec.settings)
            running = True

    manager = Manager()
    monkeypatch.setattr(module, "_settings", lambda: current)
    monkeypatch.setattr(module, "_operator_activation_required", lambda _settings: False)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_bootstrap_route", AsyncMock(return_value="active"))
    monkeypatch.setattr(
        module, "_relay_state_ready", lambda _settings, **_kwargs: True
    )
    monkeypatch.setattr(
        module,
        "_revoke_push_authority_for_opt_out",
        AsyncMock(
            side_effect=module.MobileRelayCLIError(
                "Push authority revocation was not fully confirmed"
            )
        ),
    )
    monkeypatch.setattr(module, "_write_settings", written.append)
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda value, **_kwargs: (
            manager,
            SimpleNamespace(name="relay-opt-out", settings=value),
        ),
    )

    with pytest.raises(module.MobileRelayCLIError, match="not fully confirmed"):
        module._cmd_enable(_enable_args(no_push=True))
    assert [value.push_enabled for value in installed_specs] == [False]
    assert written == [
        replace(current, push_enabled=False, push_url=current.push_url)
    ]
    assert running is True


def test_no_push_install_failure_rolls_back_before_remote_destruction(
    tmp_path, monkeypatch
):
    module = _module()
    current = replace(_settings(module, tmp_path), enabled=True)
    current.state_directory.mkdir()
    (current.state_directory / "relay.sqlite3").write_bytes(b"state")
    running = True
    installed_specs = []
    written = []

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return True

        def is_service_running(self, _name, *, system=False):
            return running

        def stop_service(self, _name, *, system=False):
            nonlocal running
            running = False

        def install_service(self, spec, *, system=False, start_now=True):
            nonlocal running
            installed_specs.append(spec.settings)
            if not spec.settings.push_enabled:
                raise OSError("no-push install failed")
            running = True

    manager = Manager()
    cleanup = AsyncMock(return_value=None)
    monkeypatch.setattr(module, "_settings", lambda: current)
    monkeypatch.setattr(module, "_operator_activation_required", lambda _settings: False)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_bootstrap_route", AsyncMock(return_value="active"))
    monkeypatch.setattr(module, "_revoke_push_authority_for_opt_out", cleanup)
    monkeypatch.setattr(module, "_write_settings", written.append)
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda value, **_kwargs: (
            manager,
            SimpleNamespace(name="relay-opt-out", settings=value),
        ),
    )

    with pytest.raises(OSError, match="no-push install failed"):
        module._cmd_enable(_enable_args(no_push=True))
    assert cleanup.await_count == 0
    assert [value.push_enabled for value in installed_specs] == [False, True]
    assert written == [
        replace(current, push_enabled=False, push_url=current.push_url),
        current,
    ]
    assert running is True


@pytest.mark.parametrize("push_enabled", [True, False])
def test_push_endpoint_change_cannot_discard_existing_or_cleanup_authority(
    tmp_path, monkeypatch, push_enabled
):
    module = _module()
    current = replace(
        _settings(module, tmp_path),
        enabled=True,
        push_enabled=push_enabled,
        push_url="https://old-push.example.test",
    )
    monkeypatch.setattr(module, "_settings", lambda: current)
    monkeypatch.setattr(module, "_push_authority_present", lambda _settings: True)
    with pytest.raises(module.MobileRelayCLIError, match="old Push authority"):
        module._cmd_enable(
            _enable_args(push_url="https://new-push.example.test")
        )


def test_hub_endpoint_change_cannot_orphan_existing_agent_route(
    tmp_path, monkeypatch
):
    module = _module()
    current = replace(
        _settings(module, tmp_path),
        enabled=True,
        hub_url="https://old-hub.example.test",
    )
    monkeypatch.setattr(module, "_settings", lambda: current)
    monkeypatch.setattr(module, "_hub_authority_present", lambda _settings: True)
    with pytest.raises(module.MobileRelayCLIError, match="old Agent route"):
        module._cmd_enable(_enable_args(hub="https://new-hub.example.test"))


def test_pending_opt_out_cleanup_blocks_reenable_at_same_endpoint(
    tmp_path, monkeypatch
):
    module = _module()
    current = replace(
        _settings(module, tmp_path),
        enabled=True,
        push_enabled=False,
        push_url="https://push.example.test",
    )
    monkeypatch.setattr(module, "_settings", lambda: current)
    monkeypatch.setattr(module, "_push_authority_present", lambda _settings: True)
    with pytest.raises(module.MobileRelayCLIError, match="cleanup remains pending"):
        module._cmd_enable(
            _enable_args(push_url="https://push.example.test")
        )


def test_validation_refuses_remote_gateway_and_weak_token_file(tmp_path):
    module = _module()
    settings = _settings(module, tmp_path)
    settings.gateway_token_file.chmod(0o644)
    try:
        module._validate_settings(settings, require_hub=True)
    except module.MobileRelayCLIError as exc:
        assert "permissions" in str(exc)
    else:
        raise AssertionError("weak token permissions accepted")
    settings.gateway_token_file.chmod(0o600)
    remote = replace(settings, gateway_host="example.test")
    try:
        module._validate_settings(remote, require_hub=True)
    except module.MobileRelayCLIError as exc:
        assert "loopback" in str(exc)
    else:
        raise AssertionError("remote Gateway accepted")


@pytest.mark.parametrize(
    "field,url",
    [
        ("hub_url", "https://user:secret@hub.example.test"),
        ("hub_url", "https://hub.example.test/base"),
        ("hub_url", "https://hub.example.test?secret=value"),
        ("push_url", "https://push.example.test#secret"),
    ],
)
def test_validation_rejects_non_origin_service_urls(tmp_path, field, url):
    module = _module()
    settings = replace(_settings(module, tmp_path), **{field: url})
    with pytest.raises(module.MobileRelayCLIError, match="must not contain"):
        module._validate_settings(settings, require_hub=True)


def test_enable_canonicalizes_service_origins_before_persistence(tmp_path, monkeypatch):
    module = _module()
    current = replace(
        _settings(module, tmp_path),
        hub_url="",
        push_url=None,
        enabled=False,
    )
    captured = {}

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return False

        def install_service(self, _spec, *, system=False, start_now=True):
            return None

        def is_service_running(self, _name, *, system=False):
            return True

        def uninstall_service(self, _name, *, system=False):
            raise AssertionError("successful enable must not roll back")

    monkeypatch.setattr(module, "_settings", lambda: current)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_operator_activation_required", lambda _settings: False)
    monkeypatch.setattr(module, "_bootstrap_route", AsyncMock(return_value="active"))
    monkeypatch.setattr(
        module,
        "_write_settings",
        lambda settings: captured.setdefault("settings", settings),
    )
    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda *_args, **_kwargs: (Manager(), SimpleNamespace(name="relay-test")),
    )
    monkeypatch.setattr(module, "_wait_for_service", lambda *_args, **_kwargs: True)
    monkeypatch.setattr(module, "_relay_state_ready", lambda *_args, **_kwargs: True)
    monkeypatch.setattr(module, "_remove_readiness_file", lambda _settings: None)
    result = module._cmd_enable(
        _enable_args(
            hub="HTTPS://Hub.Example.Test:443/",
            push_url="HTTPS://Push.Example.Test:443/",
        )
    )
    assert result == 0
    assert captured["settings"].hub_url == "https://hub.example.test"
    assert captured["settings"].push_url == "https://push.example.test"


def test_readiness_requires_matching_fresh_live_process_marker(tmp_path):
    module = _module()
    settings = _settings(module, tmp_path)
    settings.state_directory.mkdir()
    database = settings.state_directory / "relay.sqlite3"
    with sqlite3.connect(database) as connection:
        connection.executescript(
            """
            CREATE TABLE relay_identity (singleton INTEGER PRIMARY KEY);
            INSERT INTO relay_identity VALUES (1);
            CREATE TABLE agent_enrollments (
                state TEXT NOT NULL,
                route_id TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL
            );
            INSERT INTO agent_enrollments VALUES ('active','rte_agent',1);
            """
        )
    now_ms = time.time_ns() // 1_000_000
    marker = settings.state_directory / "readiness.json"

    def write_marker(*, nonce="launch-nonce", written_at_ms=now_ms):
        marker.write_text(
            json.dumps(
                {
                    "v": 1,
                    "pid": os.getpid(),
                    "launch_nonce": nonce,
                    "written_at_ms": written_at_ms,
                    "route_id": "rte_agent",
                }
            ),
            encoding="utf-8",
        )
        marker.chmod(0o600)

    write_marker()
    assert module._relay_state_ready(
        settings,
        launch_nonce="launch-nonce",
        not_before_ms=now_ms - 1,
    )
    assert not module._relay_state_ready(
        settings,
        launch_nonce="other-launch",
        not_before_ms=now_ms - 1,
    )
    write_marker(written_at_ms=now_ms - module.READINESS_MAX_AGE_MS - 1)
    assert not module._relay_state_ready(
        settings,
        launch_nonce="launch-nonce",
        not_before_ms=now_ms - module.READINESS_MAX_AGE_MS - 2,
    )
    write_marker()
    marker.chmod(0o644)
    assert not module._relay_state_ready(
        settings,
        launch_nonce="launch-nonce",
        not_before_ms=now_ms - 1,
    )


def test_status_requires_fresh_authenticated_marker_even_with_state_and_tcp(
    tmp_path, monkeypatch, capsys
):
    module = _module()
    settings = replace(_settings(module, tmp_path), enabled=True)
    settings.state_directory.mkdir()
    database = settings.state_directory / "relay.sqlite3"
    with sqlite3.connect(database) as connection:
        connection.executescript(
            """
            CREATE TABLE relay_identity (singleton INTEGER PRIMARY KEY);
            INSERT INTO relay_identity VALUES (1);
            CREATE TABLE agent_enrollments (
                state TEXT NOT NULL,
                route_id TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL
            );
            INSERT INTO agent_enrollments VALUES ('active','rte_agent',1);
            """
        )

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return True

        def is_service_running(self, _name, *, system=False):
            return True

    class Storage:
        def load_identity(self):
            return SimpleNamespace(relay_instance_id="relay_1")

        def latest_agent_enrollment(self):
            return SimpleNamespace(state="active")

        def operational_summary(self):
            return {
                "outbox": {"pending": {"count": 0}},
                "streams": [],
                "last_error_code": None,
            }

        def devices(self):
            return []

        def close(self):
            return None

    import hermes_cli.service_manager as service_manager

    monkeypatch.setattr(service_manager, "get_service_manager", lambda: Manager())
    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_service_name", lambda _home: "relay-status")
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(module, "_open_storage", lambda *_args, **_kwargs: Storage())
    args = argparse.Namespace(as_json=True)

    assert module._cmd_status(args) == 1
    missing = json.loads(capsys.readouterr().out)
    assert missing["ready"] is False
    assert missing["operational"] is False
    assert missing["readiness_error_code"] == "marker_missing"
    assert missing["last_error_code"] == "marker_missing"
    assert missing["gateway"] == {
        "host": settings.gateway_host,
        "port": settings.gateway_port,
        "tcp_available": True,
        "authenticated_ready": False,
    }

    marker = settings.state_directory / "readiness.json"
    marker.write_text(
        json.dumps(
            {
                "v": 1,
                "pid": os.getpid(),
                "launch_nonce": "status-launch-nonce",
                "written_at_ms": time.time_ns() // 1_000_000,
                "route_id": "rte_agent",
            }
        ),
        encoding="utf-8",
    )
    marker.chmod(0o600)

    class ForegroundManager:
        def is_service_installed(self, _name, *, system=False):
            return False

        def is_service_running(self, _name, *, system=False):
            return False

    monkeypatch.setattr(
        service_manager, "get_service_manager", lambda: ForegroundManager()
    )
    assert module._cmd_status(args) == 0
    ready = json.loads(capsys.readouterr().out)
    assert ready["ready"] is True
    assert ready["operational"] is True
    assert ready["service"]["running"] is False
    assert ready["readiness_error_code"] is None
    assert ready["readiness_age_ms"] >= 0
    assert ready["gateway"]["authenticated_ready"] is True


def test_compatibility_alias_rejects_shared_bearer(capsys):
    module = _module()
    result = module.compatibility_pair_command(
        argparse.Namespace(device_token=False, ttl=300, auto_approve=False, url=None)
    )
    assert result == 2
    assert "legacy v1 downgrade" in capsys.readouterr().err


def test_no_push_first_enable_requires_owner_only_operator_token_file(
    tmp_path, monkeypatch
):
    module = _module()
    settings = _settings(module, tmp_path)
    monkeypatch.setattr(module, "_settings", lambda: settings)
    args = argparse.Namespace(
        hub=None,
        push_url=None,
        no_push=True,
        system=False,
        gateway_host=None,
        gateway_port=None,
        token_file=None,
        hub_enrollment_token_file=None,
        allow_insecure_local_services=False,
    )
    try:
        module._cmd_enable(args)
    except module.MobileRelayCLIError as exc:
        assert "--hub-enrollment-token-file" in str(exc)
    else:
        raise AssertionError("first no-push enrollment accepted without authority")

    operator_file = tmp_path / "hub-enrollment.token"
    operator_file.write_text("operator-secret", encoding="utf-8")
    operator_file.chmod(0o600)
    with_file = replace(settings, hub_enrollment_token_file=operator_file)
    argv = module._relay_argv(with_file)
    assert "operator-secret" not in argv
    assert "--hub-enrollment-token-file" in argv
    assert str(operator_file) in argv


def test_first_push_enable_requires_explicit_push_gateway(tmp_path, monkeypatch):
    module = _module()
    settings = replace(
        _settings(module, tmp_path),
        hub_url="https://hub.example.test",
        push_url=None,
    )
    monkeypatch.setattr(module, "_settings", lambda: settings)
    with pytest.raises(module.MobileRelayCLIError, match="--push-url is required"):
        module._cmd_enable(_enable_args())


def test_pair_hub_override_never_infers_push_endpoint(tmp_path, monkeypatch):
    module = _module()
    settings = replace(_settings(module, tmp_path), push_url=None)
    monkeypatch.setattr(module, "_settings", lambda: settings)
    pair = AsyncMock()
    monkeypatch.setattr(module, "_pair_interactive", pair)
    with pytest.raises(module.MobileRelayCLIError, match="Push Gateway is not configured"):
        module._cmd_pair(
            argparse.Namespace(
                hub="https://new-hub.example.test",
                ttl=300,
                auto_approve=False,
            )
        )
    assert pair.await_count == 0


def test_no_push_provisional_database_still_requires_operator_token(tmp_path):
    module = _module()
    settings = replace(_settings(module, tmp_path), push_enabled=False, push_url=None)
    settings.state_directory.mkdir()
    database = settings.state_directory / "relay.sqlite3"
    with sqlite3.connect(database) as connection:
        connection.executescript(
            """
            CREATE TABLE agent_enrollments (
                enrollment_id TEXT PRIMARY KEY,
                state TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL
            );
            INSERT INTO agent_enrollments VALUES ('enroll_1', 'provisional', 1);
            """
        )
    assert module._operator_activation_required(settings) is True
    with sqlite3.connect(database) as connection:
        connection.execute(
            "UPDATE agent_enrollments SET state='active' WHERE enrollment_id='enroll_1'"
        )
    assert module._operator_activation_required(settings) is False


def test_unexpected_client_error_is_redacted(monkeypatch, capsys):
    module = _module()
    monkeypatch.setattr(
        module,
        "_cmd_devices",
        lambda _args: (_ for _ in ()).throw(RuntimeError("secret-response-body")),
    )
    result = module.mobile_command(argparse.Namespace(mobile_action="devices"))
    captured = capsys.readouterr()
    assert result == 1
    assert "RuntimeError" in captured.err
    assert "secret-response-body" not in captured.err


def test_disable_is_idempotent_and_retains_identity_state(tmp_path, monkeypatch):
    module = _module()
    settings = replace(_settings(module, tmp_path), enabled=True)
    database = settings.state_directory / "relay.sqlite3"
    database.parent.mkdir()
    database.write_bytes(b"durable identity state")
    calls: list[str] = []

    class Manager:
        installed = True
        running = True

        def is_service_installed(self, _name, *, system=False):
            return self.installed

        def is_service_running(self, _name, *, system=False):
            return self.running

        def stop_service(self, _name, *, system=False):
            calls.append("stop")
            self.running = False

        def uninstall_service(self, _name, *, system=False):
            calls.append("uninstall")
            self.installed = False

    manager = Manager()
    import hermes_cli.service_manager as service_manager

    monkeypatch.setattr(service_manager, "get_service_manager", lambda: manager)
    monkeypatch.setattr(module, "_service_name", lambda _home: "relay-idempotent")
    monkeypatch.setattr(
        module,
        "_write_settings",
        lambda value: calls.append(f"config:{value.enabled}"),
    )
    monkeypatch.setattr(module, "_settings", lambda: settings)
    args = argparse.Namespace(purge=False, yes=True)

    assert module._cmd_disable(args) == 0
    assert module._cmd_disable(args) == 0
    assert calls == ["stop", "uninstall", "config:False", "config:False"]
    assert database.read_bytes() == b"durable identity state"


@pytest.mark.parametrize("purge", [False, True])
def test_disable_fails_closed_while_foreground_runtime_owns_state(
    tmp_path, monkeypatch, purge
):
    module = _module()
    settings = replace(_settings(module, tmp_path), enabled=True)
    settings.state_directory.mkdir()
    (settings.state_directory / "relay.sqlite3").write_bytes(b"authority")
    writes = []
    remote_purge = AsyncMock()

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return False

    import hermes_cli.service_manager as service_manager
    from hermes_relay.runtime_lock import RelayRuntimeLock

    monkeypatch.setattr(service_manager, "get_service_manager", lambda: Manager())
    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_write_settings", writes.append)
    monkeypatch.setattr(module, "_purge_remote_and_local", remote_purge)

    with RelayRuntimeLock(settings.state_directory):
        with pytest.raises(
            module.MobileRelayCLIError, match="process is still running"
        ):
            module._cmd_disable(argparse.Namespace(purge=purge, yes=True))

    assert writes == []
    assert remote_purge.await_count == 0
    assert (settings.state_directory / "relay.sqlite3").is_file()


def test_lock_contention_preserves_installed_unit_and_restarts_prior_runtime(
    tmp_path, monkeypatch
):
    module = _module()
    settings = replace(_settings(module, tmp_path), enabled=True)
    calls = []

    class Manager:
        running = True

        def is_service_installed(self, _name, *, system=False):
            return True

        def is_service_running(self, _name, *, system=False):
            return self.running

        def stop_service(self, _name, *, system=False):
            calls.append("stop")
            self.running = False

        def start_service(self, _name, *, system=False):
            calls.append("restart")
            self.running = True

        def uninstall_service(self, _name, *, system=False):
            calls.append("uninstall")

    import hermes_cli.service_manager as service_manager
    from hermes_relay.runtime_lock import RelayRuntimeLock

    manager = Manager()
    monkeypatch.setattr(service_manager, "get_service_manager", lambda: manager)
    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(
        module,
        "_write_settings",
        lambda _value: calls.append("config"),
    )

    with RelayRuntimeLock(settings.state_directory):
        with pytest.raises(module.MobileRelayCLIError, match="disable was aborted"):
            module._cmd_disable(argparse.Namespace(purge=False, yes=True))

    assert calls == ["stop", "restart"]
    assert manager.running is True


def test_disable_propagates_uninstall_failure_without_changing_config_or_state(
    tmp_path, monkeypatch
):
    module = _module()
    settings = replace(_settings(module, tmp_path), enabled=True)
    settings.state_directory.mkdir()
    database = settings.state_directory / "relay.sqlite3"
    database.write_bytes(b"authority")
    writes = []
    remote_purge = AsyncMock()

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return True

        def is_service_running(self, _name, *, system=False):
            return False

        def uninstall_service(self, _name, *, system=False):
            raise RuntimeError("supervisor uninstall failed")

    import hermes_cli.service_manager as service_manager

    monkeypatch.setattr(service_manager, "get_service_manager", lambda: Manager())
    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_write_settings", writes.append)
    monkeypatch.setattr(module, "_purge_remote_and_local", remote_purge)

    with pytest.raises(RuntimeError, match="supervisor uninstall failed"):
        module._cmd_disable(argparse.Namespace(purge=True, yes=True))

    assert writes == []
    assert remote_purge.await_count == 0
    assert database.read_bytes() == b"authority"


def test_purge_removes_state_while_sibling_runtime_lock_remains_held(
    tmp_path,
):
    module = _module()
    settings = _settings(module, tmp_path)
    settings.state_directory.mkdir()
    (settings.state_directory / "relay.sqlite3").write_bytes(b"authority")
    from hermes_relay.runtime_lock import (
        RelayRuntimeAlreadyRunning,
        RelayRuntimeLock,
    )

    with RelayRuntimeLock(settings.state_directory) as held:
        assert held.path.parent == settings.state_directory.parent
        assert held.path.parent != settings.state_directory
        module._remove_state_directory(settings)
        assert not settings.state_directory.exists()
        with pytest.raises(RelayRuntimeAlreadyRunning):
            with RelayRuntimeLock(settings.state_directory):
                pass


def test_purge_is_idempotent_after_first_confirmed_revocation(tmp_path, monkeypatch):
    module = _module()
    settings = replace(_settings(module, tmp_path), enabled=True)
    database = settings.state_directory / "relay.sqlite3"
    database.parent.mkdir()
    database.write_bytes(b"authority")
    calls: list[str] = []
    purge = AsyncMock(return_value=None)

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return False

    import hermes_cli.service_manager as service_manager

    monkeypatch.setattr(service_manager, "get_service_manager", lambda: Manager())
    monkeypatch.setattr(module, "_service_name", lambda _home: "relay-purge")
    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_validate_settings", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(module, "_purge_remote_and_local", purge)
    monkeypatch.setattr(
        module,
        "_write_settings",
        lambda value: calls.append(f"config:{value.enabled}"),
    )

    def remove_state(_settings):
        calls.append("remove-state")
        database.unlink()

    monkeypatch.setattr(module, "_remove_state_directory", remove_state)
    args = argparse.Namespace(purge=True, yes=True)

    assert module._cmd_disable(args) == 0
    assert module._cmd_disable(args) == 0
    assert purge.await_count == 1
    assert calls == ["config:False", "remove-state", "config:False"]
    assert not database.exists()


def test_purge_retries_locally_revoked_device_before_agent_route_deletion(
    tmp_path, monkeypatch
):
    module = _module()
    settings = _settings(module, tmp_path)
    device = SimpleNamespace(
        device_id="dev_pending",
        status="revoked",
        hub_revocation_state="pending",
    )
    calls = []

    class Storage:
        def devices(self):
            return [device]

        def pending_hub_device_revocations(self):
            return []

        def pending_push_binding_revocations(self):
            return []

        def pending_push_exchange_revocations(self):
            return []

        def push_binding(self, _device_id):
            return None

        def destroy_local_authority(self):
            calls.append("destroy")

    class Revoker:
        async def revoke(self, device_id):
            assert device_id == device.device_id
            calls.append("retry-device")
            device.hub_revocation_state = "confirmed"

    class Hub:
        async def delete_route(self, route_id):
            calls.append("delete-agent")
            return {"route_id": route_id}

    class App:
        storage = Storage()
        revoker = Revoker()
        hub = Hub()
        relay_route = "rte_agent"

        async def reconcile_remote_revocations(self):
            calls.append("reconcile")

        async def close(self):
            calls.append("close")

    monkeypatch.setattr(module, "_create_app", AsyncMock(return_value=App()))

    asyncio.run(module._purge_remote_and_local(settings))

    assert calls == [
        "retry-device",
        "reconcile",
        "delete-agent",
        "destroy",
        "close",
    ]


def test_purge_mixed_device_failure_retains_agent_and_local_authority(
    tmp_path, monkeypatch
):
    module = _module()
    settings = _settings(module, tmp_path)
    confirmed = SimpleNamespace(
        device_id="dev_confirmed",
        status="active",
        hub_revocation_state="not_required",
    )
    pending = SimpleNamespace(
        device_id="dev_pending",
        status="revoked",
        hub_revocation_state="pending",
    )
    calls = []

    class Storage:
        def devices(self):
            return [confirmed, pending]

        def pending_hub_device_revocations(self):
            return [pending]

        def pending_push_binding_revocations(self):
            return []

        def pending_push_exchange_revocations(self):
            return []

        def push_binding(self, _device_id):
            return None

        def destroy_local_authority(self):
            raise AssertionError("local authority must survive partial remote failure")

    class Revoker:
        async def revoke(self, device_id):
            calls.append(f"revoke:{device_id}")
            if device_id == confirmed.device_id:
                confirmed.status = "revoked"
                confirmed.hub_revocation_state = "confirmed"
                return
            raise ConnectionError("simulated lost revocation response")

    class Hub:
        async def delete_route(self, _route_id):
            raise AssertionError("Agent route must be last and was reached too early")

    class App:
        storage = Storage()
        revoker = Revoker()
        hub = Hub()
        relay_route = "rte_agent"

        async def reconcile_remote_revocations(self):
            calls.append("reconcile")

        async def close(self):
            calls.append("close")

    monkeypatch.setattr(module, "_create_app", AsyncMock(return_value=App()))

    with pytest.raises(
        module.MobileRelayCLIError, match="Agent authority and local keys were retained"
    ):
        asyncio.run(module._purge_remote_and_local(settings))

    assert calls == [
        "revoke:dev_confirmed",
        "revoke:dev_pending",
        "reconcile",
        "close",
    ]


def test_runtime_dependency_preflight_satisfied_without_install(tmp_path, monkeypatch):
    module = _module()
    from tools import lazy_deps

    calls = []
    monkeypatch.setattr(
        lazy_deps,
        "ensure",
        lambda feature, *, prompt: calls.append((feature, prompt)),
    )
    package = types.ModuleType("hermes_relay")
    package.__file__ = str(tmp_path / "hermes_relay" / "__init__.py")
    monkeypatch.setitem(sys.modules, "hermes_relay", package)
    assert module._ensure_relay_runtime() == tmp_path
    assert calls == [("mobile.relay", False)]


@pytest.mark.parametrize(
    "reason",
    [
        "lazy installs disabled (security.allow_lazy_installs=false)",
        "pip install failed: offline",
    ],
)
def test_runtime_dependency_preflight_has_packager_remediation(
    reason, monkeypatch
):
    module = _module()
    from tools import lazy_deps

    def unavailable(_feature, *, prompt):
        assert prompt is False
        raise lazy_deps.FeatureUnavailable(
            "mobile.relay", ("pyhpke==0.6.5",), reason
        )

    monkeypatch.setattr(lazy_deps, "ensure", unavailable)
    with pytest.raises(module.MobileRelayCLIError) as raised:
        module._ensure_relay_runtime()
    message = str(raised.value)
    assert "hermes-agent[mobile]" in message
    assert "pip install failed:" not in message
    assert "security.allow_lazy_installs" not in message


def test_no_push_enable_activates_route_from_operator_token_file(tmp_path, monkeypatch):
    module = _module()
    settings = replace(_settings(module, tmp_path), push_enabled=False, push_url=None)
    operator_file = tmp_path / "hub-enrollment.token"
    operator_file.write_text("operator-secret", encoding="utf-8")
    operator_file.chmod(0o600)
    captured = {}

    class Storage:
        def latest_agent_enrollment(self):
            return SimpleNamespace(state="active", route_id="rte_agent")

    class App:
        storage = Storage()
        relay_route = "rte_agent"

        async def close(self):
            return None

    async def create(config):
        captured["config"] = config
        # This is the only operator authority made available to composition:
        # its protected path, never its value in argv/config/environment.
        assert config.hub_enrollment_token_file == operator_file
        assert config.hub_enrollment_token_file.read_text(encoding="utf-8") == "operator-secret"
        return App()

    class GatewayConfig(SimpleNamespace):
        def __init__(self, **values):
            super().__init__(**values)

    class V2RelayConfig(SimpleNamespace):
        def __init__(self, **values):
            super().__init__(**values)

    class V2RelayApp:
        pass

    V2RelayApp.create = staticmethod(create)

    gateway_module = types.ModuleType("hermes_relay.gateway_client")
    gateway_module.GatewayConfig = GatewayConfig
    app_module = types.ModuleType("hermes_relay.v2.app")
    app_module.V2RelayApp = V2RelayApp
    app_module.V2RelayConfig = V2RelayConfig
    app_module.read_protected_token_file = (
        lambda path, *, label: path.read_text(encoding="utf-8").strip()
    )
    monkeypatch.setitem(sys.modules, "hermes_relay.gateway_client", gateway_module)
    monkeypatch.setitem(sys.modules, "hermes_relay.v2.app", app_module)
    monkeypatch.setattr(module, "_ensure_relay_runtime", lambda: tmp_path)
    monkeypatch.setattr(module, "_settings", lambda: settings)
    monkeypatch.setattr(module, "_gateway_available", lambda *_args: True)
    monkeypatch.setattr(
        module, "_relay_state_ready", lambda _settings, **_kwargs: True
    )
    monkeypatch.setattr(module, "_write_settings", lambda _settings: None)

    class Manager:
        def is_service_installed(self, _name, *, system=False):
            return False

        def install_service(self, _spec, *, system=False, start_now=True):
            return None

        def is_service_running(self, _name, *, system=False):
            return True

        def uninstall_service(self, _name, *, system=False):
            raise AssertionError("successful activation must not roll back")

    monkeypatch.setattr(
        module,
        "_service_manager_and_spec",
        lambda _settings, **_kwargs: (
            Manager(),
            SimpleNamespace(name="relay-test"),
        ),
    )
    args = argparse.Namespace(
        hub=None,
        push_url=None,
        no_push=True,
        system=False,
        gateway_host=None,
        gateway_port=None,
        token_file=None,
        hub_enrollment_token_file=str(operator_file),
        allow_insecure_local_services=False,
    )
    assert module._cmd_enable(args) == 0
    config = captured["config"]
    assert config.hub_enrollment_token_file == operator_file
    assert "operator-secret" not in repr(config)
