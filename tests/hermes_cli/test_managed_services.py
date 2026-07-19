"""Contract tests for declarative Hermes-managed edge services."""
from __future__ import annotations

import plistlib
import subprocess
from pathlib import Path

import pytest

import hermes_cli.service_manager as sm
from hermes_cli.service_manager import (
    LaunchdServiceManager,
    S6ServiceManager,
    ServiceSpec,
    SystemdServiceManager,
    WindowsServiceManager,
    profile_scoped_service_name,
    render_systemd_service,
)


@pytest.fixture
def service_spec(tmp_path: Path) -> ServiceSpec:
    workdir = tmp_path / "Relay App"
    workdir.mkdir()
    return ServiceSpec(
        name="hermes-mobile-relay-0123456789ab",
        description="Hermes Mobile Agent Relay",
        command=("/opt/Hermes Runtime/python", "-m", "relay.v2", "--protocol", "v2"),
        working_directory=workdir,
        environment={"HERMES_HOME": str(tmp_path / "Profile A"), "RELAY_PROTOCOL": "v2"},
        stdout_path=tmp_path / "Profile A/logs/mobile-relay.out.log",
        stderr_path=tmp_path / "Profile A/logs/mobile-relay.err.log",
        restart_policy="on-failure",
    )


def test_profile_scoped_name_is_stable_and_separates_profiles(tmp_path: Path) -> None:
    first = profile_scoped_service_name("hermes-mobile-relay", tmp_path / "a")
    assert first == profile_scoped_service_name("hermes-mobile-relay", tmp_path / "a")
    assert first != profile_scoped_service_name("hermes-mobile-relay", tmp_path / "b")
    assert first.startswith("hermes-mobile-relay-")
    assert str(tmp_path) not in first


@pytest.mark.parametrize("name", ["", "Uppercase", "../escape", "space here", "a" * 128])
def test_service_spec_rejects_unsafe_names(tmp_path: Path, name: str) -> None:
    with pytest.raises(ValueError, match="service name"):
        ServiceSpec(
            name=name,
            description="test",
            command=("hermes",),
            working_directory=tmp_path,
            environment={},
            stdout_path=tmp_path / "out",
            stderr_path=tmp_path / "err",
        )


def test_service_spec_rejects_embedded_credentials(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="credential-like"):
        ServiceSpec(
            name="hermes-mobile-relay-0123456789ab",
            description="test",
            command=("hermes",),
            working_directory=tmp_path,
            environment={"HUB_SEND_TOKEN": "must-live-in-protected-state"},
            stdout_path=tmp_path / "out",
            stderr_path=tmp_path / "err",
        )


def test_systemd_renderer_preserves_argv_and_space_paths(service_spec: ServiceSpec) -> None:
    rendered = render_systemd_service(service_spec)
    assert 'ExecStart="/opt/Hermes Runtime/python" "-m" "relay.v2"' in rendered
    assert f'WorkingDirectory="{service_spec.working_directory}"' in rendered
    assert 'Environment="RELAY_PROTOCOL=v2"' in rendered
    assert "Restart=on-failure" in rendered
    assert "UMask=0077" in rendered
    assert "NoNewPrivileges=true" in rendered
    assert "ProtectSystem=strict" in rendered


def test_systemd_system_scope_uses_owner_and_multi_user_target(
    service_spec: ServiceSpec,
) -> None:
    rendered = render_systemd_service(
        service_spec,
        system=True,
        run_as_user="hermes-relay",
    )
    assert "User=hermes-relay" in rendered
    assert "WantedBy=multi-user.target" in rendered


def test_systemd_install_is_idempotent_and_profile_scoped(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []
    monkeypatch.setattr(
        sm,
        "_run_managed_command",
        lambda command, **_kwargs: calls.append(list(command)),
    )
    manager = SystemdServiceManager(user_unit_dir=tmp_path / "units")
    first = manager.install_service(service_spec)
    before = first.read_bytes()
    second = manager.install_service(service_spec)
    assert first == second
    assert second.read_bytes() == before
    assert manager.is_service_installed(service_spec.name)
    assert sum("daemon-reload" in call for call in calls) == 2
    assert sum("enable" in call for call in calls) == 2
    assert not any("restart" in call for call in calls)


def test_systemd_changed_reinstall_restarts_active_spec(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []
    monkeypatch.setattr(
        sm,
        "_run_managed_command",
        lambda command, **_kwargs: calls.append(list(command)),
    )
    manager = SystemdServiceManager(user_unit_dir=tmp_path / "units")
    manager.install_service(service_spec)
    changed = ServiceSpec(
        **{**service_spec.__dict__, "command": (*service_spec.command, "--new-hub")}
    )
    manager.install_service(changed)
    assert any("restart" in call for call in calls)


def test_systemd_failed_upgrade_restores_previous_unit(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    manager = SystemdServiceManager(user_unit_dir=tmp_path / "units")
    unit = manager._managed_unit_path(service_spec.name, system=False)
    unit.parent.mkdir(parents=True)
    unit.write_text("old-unit\n")

    def fail(_command, **_kwargs):
        raise sm.ManagedServiceCommandError("systemd", "test")

    monkeypatch.setattr(sm, "_run_managed_command", fail)
    monkeypatch.setattr(
        sm.subprocess,
        "run",
        lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 0, b"", b""),
    )
    with pytest.raises(sm.ManagedServiceCommandError):
        manager.install_service(service_spec)
    assert unit.read_text() == "old-unit\n"


def test_systemd_failed_first_enable_disables_partial_service_before_unlink(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    manager = SystemdServiceManager(user_unit_dir=tmp_path / "units")
    unit = manager._managed_unit_path(service_spec.name, system=False)
    managed_calls: list[list[str]] = []
    rollback_calls: list[list[str]] = []

    def partially_enable_then_fail(command, **_kwargs):
        managed_calls.append(list(command))
        if "enable" in command:
            raise sm.ManagedServiceCommandError("systemd", "enable after side effect")

    def rollback(command, **_kwargs):
        rollback_calls.append(list(command))
        return subprocess.CompletedProcess(command, 0, b"", b"")

    monkeypatch.setattr(sm, "_run_managed_command", partially_enable_then_fail)
    monkeypatch.setattr(sm.subprocess, "run", rollback)

    with pytest.raises(sm.ManagedServiceCommandError, match="enable after side effect"):
        manager.install_service(service_spec)

    assert not unit.exists()
    assert any("enable" in call and "--now" in call for call in managed_calls)
    assert rollback_calls[0] == [
        "systemctl",
        "--user",
        "disable",
        "--now",
        f"{service_spec.name}.service",
    ]
    assert "daemon-reload" in rollback_calls[1]


def test_systemd_failed_first_enable_preserves_unit_when_disable_is_unconfirmed(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    manager = SystemdServiceManager(user_unit_dir=tmp_path / "units")
    unit = manager._managed_unit_path(service_spec.name, system=False)
    rollback_calls: list[list[str]] = []

    def partially_enable_then_fail(command, **_kwargs):
        if "enable" in command:
            raise sm.ManagedServiceCommandError("systemd", "enable after side effect")

    def rollback(command, **_kwargs):
        rollback_calls.append(list(command))
        return subprocess.CompletedProcess(
            command,
            1 if "disable" in command else 0,
            b"",
            b"still running" if "disable" in command else b"",
        )

    monkeypatch.setattr(sm, "_run_managed_command", partially_enable_then_fail)
    monkeypatch.setattr(sm.subprocess, "run", rollback)

    with pytest.raises(sm.ManagedServiceCommandError, match="enable after side effect"):
        manager.install_service(service_spec)

    assert unit.exists(), "strict outer uninstall must retain a visible retry target"
    assert rollback_calls[0][2:4] == ["disable", "--now"]
    assert "daemon-reload" in rollback_calls[1]


def test_launchd_plist_is_structured_and_install_reconciles(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []
    monkeypatch.setattr(
        sm,
        "_run_managed_command",
        lambda command, **_kwargs: calls.append(list(command)),
    )
    monkeypatch.setattr(
        sm.subprocess,
        "run",
        lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 0, b"", b""),
    )
    manager = LaunchdServiceManager(agents_dir=tmp_path / "LaunchAgents", uid=501)
    path = manager.install_service(service_spec, start_now=True)
    payload = plistlib.loads(path.read_bytes())
    assert payload["ProgramArguments"] == list(service_spec.command)
    assert payload["EnvironmentVariables"]["RELAY_PROTOCOL"] == "v2"
    assert payload["KeepAlive"] == {"SuccessfulExit": False}
    assert payload["Umask"] == 0o077
    assert service_spec.stdout_path.stat().st_mode & 0o777 == 0o600
    assert service_spec.stderr_path.stat().st_mode & 0o777 == 0o600
    assert any(command[1] == "bootstrap" for command in calls)
    assert any(command[1] == "kickstart" for command in calls)


def test_launchd_uninstall_preserves_plist_when_bootout_fails(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    manager = LaunchdServiceManager(agents_dir=tmp_path / "LaunchAgents", uid=501)
    plist = manager._managed_plist_path(service_spec.name)
    plist.parent.mkdir(parents=True)
    plist.write_bytes(manager._render_plist(service_spec, start_now=True))

    monkeypatch.setattr(
        sm.subprocess,
        "run",
        lambda *args, **kwargs: subprocess.CompletedProcess(
            args[0], 5, "", "operation not permitted"
        ),
    )
    with pytest.raises(sm.ManagedServiceCommandError):
        manager.uninstall_service(service_spec.name)
    assert plist.is_file()


def test_windows_install_uses_task_xml_and_keeps_secrets_out_of_task_name(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def fake_schtasks(args: list[str]):
        calls.append(args)
        return 0, "success", ""

    import hermes_cli.gateway_windows as gateway_windows

    monkeypatch.setattr(gateway_windows, "_exec_schtasks", fake_schtasks)
    manager = WindowsServiceManager(services_dir=tmp_path / "services")
    script = manager.install_service(service_spec)
    assert script.is_file()
    assert 'cd /d "' in script.read_text()
    assert any("/Create" in call and "/XML" in call for call in calls)
    assert any("/Run" in call for call in calls)
    assert str(service_spec.working_directory) not in manager._task_name(service_spec.name)


def test_windows_changed_reinstall_ends_old_instance_before_run(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def fake_schtasks(args: list[str]):
        calls.append(args)
        if "/Query" in args and "/V" in args:
            return 0, "Status: Running", ""
        return 0, "success", ""

    import hermes_cli.gateway_windows as gateway_windows

    monkeypatch.setattr(gateway_windows, "_exec_schtasks", fake_schtasks)
    manager = WindowsServiceManager(services_dir=tmp_path / "services")
    manager.install_service(service_spec)
    calls.clear()
    manager.install_service(service_spec)
    create_index = next(i for i, call in enumerate(calls) if "/Create" in call)
    end_index = next(i for i, call in enumerate(calls) if "/End" in call)
    run_index = next(i for i, call in enumerate(calls) if "/Run" in call)
    assert create_index < end_index < run_index


def test_windows_command_renderer_quotes_cmd_metacharacters(
    service_spec: ServiceSpec,
) -> None:
    dangerous = ServiceSpec(
        **{
            **service_spec.__dict__,
            "command": ("C:/Hermes/python.exe", "value&whoami", "%USERPROFILE%"),
        }
    )
    script = WindowsServiceManager._render_script(dangerous)
    assert '"value&whoami"' in script
    assert '"%%USERPROFILE%%"' in script


def test_s6_generic_service_install_start_stop_and_remove(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def fake_run(command, **_kwargs):
        calls.append(list(command))
        stdout = "up (pid 123)" if "s6-svstat" in command[0] else ""
        return subprocess.CompletedProcess(command, 0, stdout, "")

    monkeypatch.setattr(sm.subprocess, "run", fake_run)
    manager = S6ServiceManager(scandir=tmp_path / "service")
    path = manager.install_service(service_spec, start_now=False)
    assert path.is_dir()
    assert (path / "down").exists()
    assert shlex_command_present(path / "run", service_spec.command[0])
    assert "umask 077" in (path / "run").read_text()
    manager.start_service(service_spec.name)
    assert not (path / "down").exists()
    manager.stop_service(service_spec.name)
    assert (path / "down").exists()
    manager.uninstall_service(service_spec.name)
    assert not path.exists()
    assert any("s6-svscanctl" in call[0] for call in calls)


def test_s6_reinstall_waits_for_old_process_exit_before_swap(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def fake_run(command, **_kwargs):
        calls.append(list(command))
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(sm.subprocess, "run", fake_run)
    manager = S6ServiceManager(scandir=tmp_path / "service")
    manager.install_service(service_spec)
    calls.clear()
    manager.install_service(service_spec)
    stop_index = next(i for i, call in enumerate(calls) if "s6-svc" in call[0])
    wait_index = next(i for i, call in enumerate(calls) if "s6-svwait" in call[0])
    scan_index = next(i for i, call in enumerate(calls) if "s6-svscanctl" in call[0])
    assert stop_index < wait_index < scan_index


def test_s6_failed_wait_restores_prior_up_state(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def fake_run(command, **_kwargs):
        calls.append(list(command))
        if "s6-svwait" in command[0]:
            return subprocess.CompletedProcess(command, 1, "", "timeout")
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(sm.subprocess, "run", fake_run)
    manager = S6ServiceManager(scandir=tmp_path / "service")
    # Seed without exercising the failing reinstall path.
    service_dir = manager.scandir / service_spec.name
    service_dir.mkdir(parents=True)
    (service_dir / "run").write_text("old-run\n")

    with pytest.raises(sm.ManagedServiceCommandError):
        manager.install_service(service_spec)
    assert service_dir.is_dir()
    assert (service_dir / "run").read_text() == "old-run\n"
    assert any("s6-svc" in call[0] and "-u" in call for call in calls)


def test_s6_failed_swap_restores_backup_directory(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def fake_run(command, **_kwargs):
        calls.append(list(command))
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(sm.subprocess, "run", fake_run)
    manager = S6ServiceManager(scandir=tmp_path / "service")
    service_dir = manager.scandir / service_spec.name
    service_dir.mkdir(parents=True)
    (service_dir / "run").write_text("old-run\n")
    original_rename = Path.rename

    def fail_staging_swap(path: Path, target: Path):
        if path.name == f".{service_spec.name}.tmp":
            raise OSError("simulated staging rename failure")
        return original_rename(path, target)

    monkeypatch.setattr(Path, "rename", fail_staging_swap)
    with pytest.raises(OSError, match="staging rename failure"):
        manager.install_service(service_spec)
    assert service_dir.is_dir()
    assert (service_dir / "run").read_text() == "old-run\n"
    assert not (manager.scandir / f".{service_spec.name}.backup").exists()
    assert any("s6-svc" in call[0] and "-u" in call for call in calls)


def test_s6_uninstall_wait_failure_preserves_service_directory(
    tmp_path: Path,
    service_spec: ServiceSpec,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service_dir = tmp_path / "service" / service_spec.name
    service_dir.mkdir(parents=True)

    def fake_run(command, **_kwargs):
        return subprocess.CompletedProcess(
            command,
            1 if "s6-svwait" in command[0] else 0,
            "",
            "timeout" if "s6-svwait" in command[0] else "",
        )

    monkeypatch.setattr(sm.subprocess, "run", fake_run)
    manager = S6ServiceManager(scandir=tmp_path / "service")
    with pytest.raises(sm.ManagedServiceCommandError):
        manager.uninstall_service(service_spec.name)
    assert service_dir.is_dir()


def shlex_command_present(path: Path, executable: str) -> bool:
    """Keep the assertion readable without depending on shell execution."""
    return executable in path.read_text()
