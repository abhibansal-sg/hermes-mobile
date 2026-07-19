"""Abstract service manager interface.

Wraps systemd (Linux host), launchd (macOS host), Windows Scheduled Task
(native Windows host), and s6 (container) backends behind a common Protocol.
All backends can install a declarative :class:`ServiceSpec` for trusted edge
processes such as the Mobile Agent Relay. Only s6 supports the older runtime
*profile-gateway* registration API; host backends raise NotImplementedError
from those profile-specific methods.

Host-side call sites (setup wizard, uninstall, status) continue to use
the existing module-level gateway functions directly. Backend-neutral edge
services use ``ServiceSpec`` through this facade, while profile create/delete
hooks and the container gateway dispatch continue to use the s6-specific API.
"""
from __future__ import annotations

import hashlib
import os
import re
import shlex
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Mapping, Protocol, runtime_checkable

ServiceManagerKind = Literal["systemd", "launchd", "windows", "s6", "none"]
RestartPolicy = Literal["always", "on-failure", "never"]
_SENSITIVE_ENV_RE = re.compile(
    r"(?:^|_)(?:API_KEY|PRIVATE_KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL|CAPABILITY)(?:$|_)",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class ServiceSpec:
    """Declarative description of a Hermes-managed background process.

    ``ServiceSpec`` intentionally contains only process metadata. Credentials
    stay in the profile's protected state store and are loaded by the process;
    callers should only place non-secret values such as ``HERMES_HOME`` in
    ``environment``.
    """

    name: str
    description: str
    command: tuple[str, ...] | list[str]
    working_directory: Path
    environment: Mapping[str, str]
    stdout_path: Path
    stderr_path: Path
    restart_policy: RestartPolicy = "on-failure"

    def __post_init__(self) -> None:
        validate_service_name(self.name)
        if not isinstance(self.description, str) or not self.description.strip():
            raise ValueError("service description must not be empty")
        if any(char in self.description for char in ("\x00", "\r", "\n")):
            raise ValueError("service description must be a single NUL-free line")
        if not isinstance(self.command, (tuple, list)) or not self.command or any(
            not isinstance(arg, str) or any(char in arg for char in ("\x00", "\r", "\n"))
            for arg in self.command
        ):
            raise ValueError("service command must contain non-empty, NUL-free arguments")
        if not str(self.command[0]).strip():
            raise ValueError("service executable must not be empty")
        if self.restart_policy not in ("always", "on-failure", "never"):
            raise ValueError(f"unsupported restart policy: {self.restart_policy!r}")
        if not isinstance(self.environment, Mapping):
            raise ValueError("service environment must be a string mapping")
        if not all(
            isinstance(path, Path)
            for path in (
                self.working_directory,
                self.stdout_path,
                self.stderr_path,
            )
        ):
            raise ValueError("service paths must be pathlib.Path values")
        for key, value in self.environment.items():
            if not isinstance(key, str) or not re.fullmatch(
                r"[A-Za-z_][A-Za-z0-9_]*", key
            ):
                raise ValueError(f"invalid environment variable name: {key!r}")
            if _SENSITIVE_ENV_RE.search(key):
                raise ValueError(
                    f"service environment must not embed credential-like value: {key!r}"
                )
            if not isinstance(value, str) or any(
                char in value for char in ("\x00", "\r", "\n")
            ):
                raise ValueError(f"invalid environment value for {key!r}")


_VALID_SERVICE_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,126}$")


def validate_service_name(name: str) -> None:
    """Validate a portable systemd/launchd/s6/Task Scheduler name."""
    if not _VALID_SERVICE_RE.fullmatch(name):
        raise ValueError(
            "service name must be 1-127 lowercase letters, digits, dots, "
            f"underscores, or dashes, got {name!r}"
        )


def profile_scoped_service_name(
    base: str,
    hermes_home: Path | str | None = None,
) -> str:
    """Return a stable service name unique to the active ``HERMES_HOME``.

    Hashing the normalized absolute profile directory prevents two Hermes
    profiles from replacing each other's relay service while keeping paths and
    usernames out of the service label.
    """
    validate_service_name(base)
    if hermes_home is None:
        from hermes_constants import get_hermes_home

        home = Path(get_hermes_home())
    else:
        home = Path(hermes_home)
    normalized = os.path.normcase(str(home.expanduser().resolve(strict=False)))
    suffix = hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:12]
    name = f"{base}-{suffix}"
    validate_service_name(name)
    return name


# Profile name → service directory mapping. Profile names must be safe
# as filesystem directory names because the s6 backend creates a service
# directory at ``<scandir>/gateway-<profile>/``. We reject anything that
# could traverse paths, span filesystems, or break s6's own naming rules.
_VALID_PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
_MAX_PROFILE_LEN = 251  # s6-svscan default name_max


def validate_profile_name(name: str) -> None:
    """Raise ValueError if ``name`` is not usable as a profile name.

    Profile names are used as s6 service directory names, so they must
    match a conservative subset of filesystem-safe characters. Reject
    empty strings, uppercase, paths-traversal sequences, and anything
    longer than s6's default ``name_max``.
    """
    if not name:
        raise ValueError("profile name must not be empty")
    if len(name) > _MAX_PROFILE_LEN:
        raise ValueError(
            f"profile name too long ({len(name)} > {_MAX_PROFILE_LEN})"
        )
    if not _VALID_PROFILE_RE.match(name):
        raise ValueError(
            f"profile name must match [a-z0-9][a-z0-9_-]*, got {name!r}"
        )


@runtime_checkable
class ServiceManager(Protocol):
    """Abstract interface for init-system-specific service operations.

    Legacy gateway lifecycle methods (start / stop / restart / is_running)
    and declarative managed-service methods are implemented by every backend.
    Profile-gateway runtime registration
    (register_profile_gateway / unregister_profile_gateway /
    list_profile_gateways) is implemented only by the s6 backend —
    callers MUST check ``supports_runtime_registration()`` before
    invoking the registration methods.
    """

    kind: ServiceManagerKind

    # Lifecycle of a pre-declared service.
    def start(self, name: str) -> None: ...
    def stop(self, name: str) -> None: ...
    def restart(self, name: str) -> None: ...
    def is_running(self, name: str) -> bool: ...

    # Declarative managed services (Agent Relay and future edge services).
    def install_service(
        self,
        spec: ServiceSpec,
        *,
        system: bool = False,
        start_now: bool = True,
    ) -> Path: ...
    def uninstall_service(self, name: str, *, system: bool = False) -> None: ...
    def start_service(self, name: str, *, system: bool = False) -> None: ...
    def stop_service(self, name: str, *, system: bool = False) -> None: ...
    def restart_service(self, name: str, *, system: bool = False) -> None: ...
    def is_service_running(self, name: str, *, system: bool = False) -> bool: ...
    def is_service_installed(self, name: str, *, system: bool = False) -> bool: ...

    # Runtime registration (s6 only).
    def supports_runtime_registration(self) -> bool: ...
    def register_profile_gateway(
        self,
        profile: str,
        *,
        extra_env: dict[str, str] | None = None,
        start_now: bool = True,
    ) -> None: ...
    def unregister_profile_gateway(self, profile: str) -> None: ...
    def list_profile_gateways(self) -> list[str]: ...


def detect_service_manager() -> ServiceManagerKind:
    """Detect which service manager is available in this environment.

    Returns:
        "s6" — s6-svscan is PID 1 (s6-overlay image; Docker, Podman, or a
               Fly Firecracker microVM)
        "windows" — native Windows host
        "launchd" — macOS host
        "systemd" — Linux host with a working user/system bus
        "none" — anything else (Termux, sandbox shells, etc.)

    This function does NOT replace ``supports_systemd_services()`` —
    host call sites continue to use that. It exists for new backend-
    agnostic code (profile create/delete hooks, the s6 dispatch path
    in ``hermes gateway start/stop/restart``).
    """
    # Imports deferred so importing this module doesn't drag in the
    # whole gateway dependency graph for callers that only need the
    # Protocol type or validate_profile_name().
    from hermes_cli.gateway import (
        is_macos,
        is_windows,
        supports_systemd_services,
    )

    # Gate on _s6_running() alone (PID 1 comm == s6-svscan AND /run/s6/basedir),
    # NOT is_container(): the latter only detects Docker/Podman/lxc, so it is
    # False on Fly's Firecracker microVMs even though s6-overlay is PID 1 there.
    # That false negative made the whole s6 dispatch path inert on Fly, so
    # `hermes gateway start/stop/restart` fell through to host code that spawns
    # a foreground gateway competing with the supervised one. _s6_running() is
    # already an s6-overlay-specific signal, so the container gate was redundant.
    if _s6_running():
        return "s6"
    if is_windows():
        return "windows"
    if is_macos():
        return "launchd"
    if supports_systemd_services():
        return "systemd"
    return "none"


def _s6_running() -> bool:
    """True when s6-svscan is running as PID 1 in this container.

    Detection has to work for **both** root and the unprivileged hermes
    user (UID 10000). The obvious probe — ``Path('/proc/1/exe').resolve()``
    — only works as root: for any other UID, the symlink at
    ``/proc/1/exe`` is unreadable and ``resolve()`` silently returns the
    path unchanged, so the resolved name is the literal ``"exe"`` and
    detection always fails. Since every Hermes runtime call inside the
    container drops to hermes via ``s6-setuidgid``, that silent failure
    made the entire service-manager runtime-registration path inert in
    production (PR #30136 review).

    Probe instead via:
      * ``/proc/1/comm`` — world-readable, contains the process comm
        (``s6-svscan`` when s6-overlay is PID 1).
      * ``/run/s6/basedir`` — s6-overlay-specific directory created by
        stage1. World-readable. More specific than ``/run/s6`` (which
        other tools occasionally create).

    Both signals are required; either alone could false-positive
    (e.g. a container with the s6 binaries installed but a different
    init, or an unrelated process named ``s6-svscan``).
    """
    try:
        comm = Path("/proc/1/comm").read_text(encoding="utf-8").strip()
    except OSError:
        return False
    if comm != "s6-svscan":
        return False
    return Path("/run/s6/basedir").is_dir()


# ---------------------------------------------------------------------------
# Backend wrappers
#
# Legacy ``start``/``stop`` methods remain thin facades over the existing
# gateway functions, where the ``name`` argument is intentionally ignored on
# hosts. The ``*_service`` methods below are the generic, name-aware path used
# for declarative edge services and never change legacy gateway behavior.
# ---------------------------------------------------------------------------


class _RegistrationUnsupportedMixin:
    """Mixin for host backends that don't support runtime registration."""

    def supports_runtime_registration(self) -> bool:
        return False

    def register_profile_gateway(
        self,
        profile: str,
        *,
        extra_env: dict[str, str] | None = None,
        start_now: bool = True,
    ) -> None:
        raise NotImplementedError(
            f"{type(self).__name__} does not support runtime profile "
            "gateway registration (container-only feature)"
        )

    def unregister_profile_gateway(self, profile: str) -> None:
        raise NotImplementedError(
            f"{type(self).__name__} does not support runtime profile "
            "gateway unregistration (container-only feature)"
        )

    def list_profile_gateways(self) -> list[str]:
        return []


def _atomic_write(path: Path, content: str | bytes, *, mode: int = 0o644) -> None:
    """Atomically replace ``path`` without exposing a partial service file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    binary = isinstance(content, bytes)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(
            fd,
            "wb" if binary else "w",
            encoding=None if binary else "utf-8",
        ) as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        tmp_path.chmod(mode)
        os.replace(tmp_path, path)
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


def _prepare_service_paths(spec: ServiceSpec) -> None:
    if any(
        char in str(path)
        for path in (spec.working_directory, spec.stdout_path, spec.stderr_path)
        for char in ("\r", "\n")
    ):
        raise ValueError("service paths must not contain newlines")
    if not spec.working_directory.is_dir():
        raise FileNotFoundError(
            f"service working directory does not exist: {spec.working_directory}"
        )
    spec.stdout_path.parent.mkdir(parents=True, exist_ok=True)
    spec.stderr_path.parent.mkdir(parents=True, exist_ok=True)
    for path in {spec.stdout_path, spec.stderr_path}:
        path.touch(exist_ok=True)
        if os.name == "posix":
            path.chmod(0o600)


def _systemd_quote(value: str) -> str:
    """Quote one systemd directive value without invoking a shell."""
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("%", "%%")
        .replace("$", "$$")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )
    return f'"{escaped}"'


def render_systemd_service(
    spec: ServiceSpec,
    *,
    system: bool = False,
    run_as_user: str | None = None,
) -> str:
    """Render a hardened systemd unit for a declarative service."""
    restart = {
        "always": "always",
        "on-failure": "on-failure",
        "never": "no",
    }[spec.restart_policy]
    lines = [
        "[Unit]",
        f"Description={spec.description}",
        "Wants=network-online.target",
        "After=network-online.target",
        "",
        "[Service]",
        "Type=simple",
        "ExecStart=" + " ".join(_systemd_quote(arg) for arg in spec.command),
        f"WorkingDirectory={_systemd_quote(str(spec.working_directory))}",
    ]
    if run_as_user:
        lines.append(f"User={run_as_user}")
    for key, value in sorted(spec.environment.items()):
        lines.append(f"Environment={_systemd_quote(f'{key}={value}')}")
    writable_paths = {spec.stdout_path.parent, spec.stderr_path.parent}
    configured_home = spec.environment.get("HERMES_HOME")
    if configured_home:
        writable_paths.add(Path(configured_home))
    lines.extend(
        [
            f"StandardOutput={_systemd_quote(f'append:{spec.stdout_path}')}",
            f"StandardError={_systemd_quote(f'append:{spec.stderr_path}')}",
            f"Restart={restart}",
            "RestartSec=2s",
            "UMask=0077",
            "NoNewPrivileges=true",
            "PrivateTmp=true",
            "ProtectSystem=strict",
            "ProtectHome=read-only",
            f"ReadOnlyPaths={_systemd_quote(str(spec.working_directory))}",
            "ReadWritePaths="
            + " ".join(_systemd_quote(str(path)) for path in sorted(writable_paths)),
            "",
            "[Install]",
            f"WantedBy={'multi-user.target' if system else 'default.target'}",
            "",
        ]
    )
    return "\n".join(lines)


class ManagedServiceCommandError(RuntimeError):
    """Raised when an init-system command fails."""

    def __init__(self, manager: str, action: str, detail: str = "") -> None:
        message = f"{manager} could not {action} managed service"
        if detail:
            message += f": {detail.strip()}"
        super().__init__(message)


def _run_managed_command(command: list[str], *, manager: str, action: str) -> None:
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ManagedServiceCommandError(manager, action, str(exc)) from exc
    if result.returncode != 0:
        raise ManagedServiceCommandError(
            manager,
            action,
            result.stderr or result.stdout or f"exit {result.returncode}",
        )


def _run_managed_rollback(command: list[str]) -> bool:
    """Run rollback cleanup without replacing the triggering exception."""

    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


class SystemdServiceManager(_RegistrationUnsupportedMixin):
    """Thin wrapper around the ``systemd_*`` functions in hermes_cli.gateway.

    Existing host call sites continue to use those functions directly;
    this wrapper exists for new code that needs to be backend-agnostic
    (the Phase 4 profile create/delete hooks).
    """

    kind: ServiceManagerKind = "systemd"

    def __init__(
        self,
        *,
        user_unit_dir: Path | None = None,
        system_unit_dir: Path | None = None,
    ) -> None:
        self.user_unit_dir = user_unit_dir or Path.home() / ".config/systemd/user"
        self.system_unit_dir = system_unit_dir or Path("/etc/systemd/system")

    def _managed_unit_path(self, name: str, *, system: bool) -> Path:
        validate_service_name(name)
        root = self.system_unit_dir if system else self.user_unit_dir
        return root / f"{name}.service"

    @staticmethod
    def _systemctl(*args: str, system: bool) -> list[str]:
        return ["systemctl", *([] if system else ["--user"]), *args]

    def install_service(
        self,
        spec: ServiceSpec,
        *,
        system: bool = False,
        start_now: bool = True,
    ) -> Path:
        if system and os.name != "nt" and os.geteuid() != 0:
            raise PermissionError("system service installation requires root")
        _prepare_service_paths(spec)
        unit_path = self._managed_unit_path(spec.name, system=system)
        previous = unit_path.read_bytes() if unit_path.exists() else None
        run_as_user: str | None = None
        if system:
            import pwd

            owner_path = Path(spec.environment.get("HERMES_HOME", spec.working_directory))
            run_as_user = pwd.getpwuid(owner_path.stat().st_uid).pw_name
        rendered = render_systemd_service(
            spec,
            system=system,
            run_as_user=run_as_user,
        ).encode("utf-8")
        changed = previous is not None and previous != rendered
        try:
            _atomic_write(unit_path, rendered)
            _run_managed_command(
                self._systemctl("daemon-reload", system=system),
                manager="systemd",
                action="reload units",
            )
            enable_args = [
                "enable",
                *(["--now"] if start_now else []),
                f"{spec.name}.service",
            ]
            _run_managed_command(
                self._systemctl(*enable_args, system=system),
                manager="systemd",
                action=f"enable {spec.name}",
            )
            if start_now and changed:
                _run_managed_command(
                    self._systemctl(
                        "restart", f"{spec.name}.service", system=system
                    ),
                    manager="systemd",
                    action=f"restart {spec.name} with updated specification",
                )
        except Exception:
            if previous is None:
                # `enable --now` is not transactional: systemd may create the
                # enable symlink and start the unit before returning non-zero.
                # Stop/disable by name while the new unit is still present so
                # a failed first install cannot leave a restarting process.
                disabled = _run_managed_rollback(
                    self._systemctl(
                        "disable",
                        "--now",
                        f"{spec.name}.service",
                        system=system,
                    )
                )
                # Keep the unit file when disable could not be confirmed. The
                # caller's strict uninstall rollback can then see it and retry;
                # deleting it here would hide a loaded/restarting orphan.
                if disabled:
                    unit_path.unlink(missing_ok=True)
            else:
                _atomic_write(unit_path, previous)
            _run_managed_rollback(
                self._systemctl("daemon-reload", system=system)
            )
            if previous is not None and start_now:
                _run_managed_rollback(
                    self._systemctl(
                        "restart", f"{spec.name}.service", system=system
                    )
                )
            raise
        return unit_path

    def uninstall_service(self, name: str, *, system: bool = False) -> None:
        unit_path = self._managed_unit_path(name, system=system)
        if not unit_path.exists():
            return
        _run_managed_command(
            self._systemctl("disable", "--now", f"{name}.service", system=system),
            manager="systemd",
            action=f"disable {name}",
        )
        unit_path.unlink(missing_ok=True)
        _run_managed_command(
            self._systemctl("daemon-reload", system=system),
            manager="systemd",
            action="reload units",
        )

    def start_service(self, name: str, *, system: bool = False) -> None:
        validate_service_name(name)
        _run_managed_command(
            self._systemctl("start", f"{name}.service", system=system),
            manager="systemd",
            action=f"start {name}",
        )

    def stop_service(self, name: str, *, system: bool = False) -> None:
        validate_service_name(name)
        _run_managed_command(
            self._systemctl("stop", f"{name}.service", system=system),
            manager="systemd",
            action=f"stop {name}",
        )

    def restart_service(self, name: str, *, system: bool = False) -> None:
        validate_service_name(name)
        _run_managed_command(
            self._systemctl("restart", f"{name}.service", system=system),
            manager="systemd",
            action=f"restart {name}",
        )

    def is_service_running(self, name: str, *, system: bool = False) -> bool:
        validate_service_name(name)
        result = subprocess.run(
            self._systemctl("is-active", "--quiet", f"{name}.service", system=system),
            check=False,
            capture_output=True,
            timeout=10,
        )
        return result.returncode == 0

    def is_service_installed(self, name: str, *, system: bool = False) -> bool:
        return self._managed_unit_path(name, system=system).is_file()

    def start(self, name: str) -> None:
        from hermes_cli.gateway import systemd_start
        systemd_start()

    def stop(self, name: str) -> None:
        from hermes_cli.gateway import systemd_stop
        systemd_stop()

    def restart(self, name: str) -> None:
        from hermes_cli.gateway import systemd_restart
        systemd_restart()

    def is_running(self, name: str) -> bool:
        from hermes_cli.gateway import _probe_systemd_service_running
        _, running = _probe_systemd_service_running()
        return running


class LaunchdServiceManager(_RegistrationUnsupportedMixin):
    """Thin wrapper around the ``launchd_*`` functions in hermes_cli.gateway."""

    kind: ServiceManagerKind = "launchd"

    def __init__(self, *, agents_dir: Path | None = None, uid: int | None = None) -> None:
        self.agents_dir = agents_dir or Path.home() / "Library/LaunchAgents"
        self.uid = os.getuid() if uid is None else uid

    @staticmethod
    def _label(name: str) -> str:
        validate_service_name(name)
        return f"ai.hermes.{name}"

    def _managed_plist_path(self, name: str) -> Path:
        return self.agents_dir / f"{self._label(name)}.plist"

    @property
    def _domain(self) -> str:
        return f"gui/{self.uid}"

    def _target(self, name: str) -> str:
        return f"{self._domain}/{self._label(name)}"

    def _bootout(self, name: str, *, allow_absent: bool) -> None:
        result = subprocess.run(
            ["launchctl", "bootout", self._target(name)],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return
        detail = (result.stderr or result.stdout or "").strip()
        lowered = detail.lower()
        absent = any(
            marker in lowered
            for marker in ("could not find service", "no such process", "not found")
        )
        if not (allow_absent and absent):
            raise ManagedServiceCommandError(
                "launchd", f"stop {name}", detail or f"exit {result.returncode}"
            )

    @staticmethod
    def _render_plist(spec: ServiceSpec, *, start_now: bool) -> bytes:
        import plistlib

        keep_alive: bool | dict[str, bool]
        if spec.restart_policy == "always":
            keep_alive = True
        elif spec.restart_policy == "on-failure":
            keep_alive = {"SuccessfulExit": False}
        else:
            keep_alive = False
        payload: dict[str, object] = {
            "Label": LaunchdServiceManager._label(spec.name),
            "ProgramArguments": list(spec.command),
            "WorkingDirectory": str(spec.working_directory),
            "EnvironmentVariables": dict(spec.environment),
            "StandardOutPath": str(spec.stdout_path),
            "StandardErrorPath": str(spec.stderr_path),
            "RunAtLoad": start_now,
            "KeepAlive": keep_alive,
            "ProcessType": "Background",
            "Umask": 0o077,
        }
        return plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=True)

    def install_service(
        self,
        spec: ServiceSpec,
        *,
        system: bool = False,
        start_now: bool = True,
    ) -> Path:
        if system:
            raise NotImplementedError(
                "managed launchd services currently support per-user LaunchAgents only"
            )
        _prepare_service_paths(spec)
        plist_path = self._managed_plist_path(spec.name)
        previous = plist_path.read_bytes() if plist_path.exists() else None
        target = self._target(spec.name)
        self._bootout(spec.name, allow_absent=True)
        try:
            _atomic_write(plist_path, self._render_plist(spec, start_now=start_now))
            _run_managed_command(
                ["launchctl", "bootstrap", self._domain, str(plist_path)],
                manager="launchd",
                action=f"install {spec.name}",
            )
            if start_now:
                _run_managed_command(
                    ["launchctl", "kickstart", "-k", target],
                    manager="launchd",
                    action=f"start {spec.name}",
                )
        except Exception:
            subprocess.run(
                ["launchctl", "bootout", target],
                check=False,
                capture_output=True,
                timeout=10,
            )
            if previous is None:
                plist_path.unlink(missing_ok=True)
            else:
                _atomic_write(plist_path, previous)
                subprocess.run(
                    ["launchctl", "bootstrap", self._domain, str(plist_path)],
                    check=False,
                    capture_output=True,
                    timeout=10,
                )
            raise
        return plist_path

    def uninstall_service(self, name: str, *, system: bool = False) -> None:
        if system:
            raise NotImplementedError("launchd system service removal is not supported")
        plist_path = self._managed_plist_path(name)
        if not plist_path.exists():
            return
        self._bootout(name, allow_absent=True)
        plist_path.unlink(missing_ok=True)

    def start_service(self, name: str, *, system: bool = False) -> None:
        if system:
            raise NotImplementedError("launchd system services are not supported")
        plist_path = self._managed_plist_path(name)
        if not plist_path.is_file():
            raise FileNotFoundError(f"managed launchd service is not installed: {name}")
        probe = subprocess.run(
            ["launchctl", "print", self._target(name)],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if probe.returncode != 0:
            _run_managed_command(
                ["launchctl", "bootstrap", self._domain, str(plist_path)],
                manager="launchd",
                action=f"load {name}",
            )
        _run_managed_command(
            ["launchctl", "kickstart", "-k", self._target(name)],
            manager="launchd",
            action=f"start {name}",
        )

    def stop_service(self, name: str, *, system: bool = False) -> None:
        if system:
            raise NotImplementedError("launchd system services are not supported")
        self._bootout(name, allow_absent=True)

    def restart_service(self, name: str, *, system: bool = False) -> None:
        self.stop_service(name, system=system)
        self.start_service(name, system=system)

    def is_service_running(self, name: str, *, system: bool = False) -> bool:
        if system:
            return False
        result = subprocess.run(
            ["launchctl", "print", self._target(name)],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.returncode == 0 and "state = running" in result.stdout

    def is_service_installed(self, name: str, *, system: bool = False) -> bool:
        return not system and self._managed_plist_path(name).is_file()

    def start(self, name: str) -> None:
        from hermes_cli.gateway import launchd_start
        launchd_start()

    def stop(self, name: str) -> None:
        from hermes_cli.gateway import launchd_stop
        launchd_stop()

    def restart(self, name: str) -> None:
        from hermes_cli.gateway import launchd_restart
        launchd_restart()

    def is_running(self, name: str) -> bool:
        from hermes_cli.gateway import _probe_launchd_service_running
        return _probe_launchd_service_running()


class WindowsServiceManager(_RegistrationUnsupportedMixin):
    """Thin wrapper around ``hermes_cli.gateway_windows`` (Scheduled Task /
    Startup-folder fallback).

    The native Windows backend uses a Scheduled Task rather than a true
    init-system service, but for protocol purposes the lifecycle is the
    same: start / stop / restart / is_running. ``install`` accepts a
    handful of Windows-specific kwargs (start_now, start_on_login,
    elevated_handoff) that are passed straight through — non-Windows
    callers should never invoke ``install`` on this wrapper.
    """

    kind: ServiceManagerKind = "windows"

    def __init__(self, *, services_dir: Path | None = None) -> None:
        default_root = Path(
            os.environ.get(
                "LOCALAPPDATA",
                str(Path.home() / "AppData" / "Local"),
            )
        )
        self.services_dir = services_dir or default_root / "Hermes" / "services"

    @staticmethod
    def _task_name(name: str) -> str:
        validate_service_name(name)
        return rf"Hermes\{name}"

    def _script_path(self, name: str) -> Path:
        validate_service_name(name)
        return self.services_dir / f"{name}.cmd"

    @staticmethod
    def _cmd_argument(value: str) -> str:
        # ``list2cmdline`` targets the Windows CRT, while this command first
        # passes through cmd.exe. Quote every argument (not only whitespace)
        # so &, |, <, > and parentheses remain data, and double percent signs
        # so cmd does not expand environment references inside arguments.
        escaped = subprocess.list2cmdline([value.replace("%", "%%")])
        return escaped if escaped.startswith('"') else f'"{escaped}"'

    @staticmethod
    def _render_script(spec: ServiceSpec) -> str:
        for value in spec.environment.values():
            if '"' in value or "\r" in value or "\n" in value:
                raise ValueError(
                    "Windows service environment values cannot contain quotes or newlines"
                )
        lines = ["@echo off", "setlocal DisableDelayedExpansion"]
        for key, value in sorted(spec.environment.items()):
            lines.append(f'set "{key}={value.replace("%", "%%")}"')
        working_directory = str(spec.working_directory).replace("%", "%%")
        stdout_path = str(spec.stdout_path).replace("%", "%%")
        stderr_path = str(spec.stderr_path).replace("%", "%%")
        lines.append(f'cd /d "{working_directory}"')
        command = " ".join(
            WindowsServiceManager._cmd_argument(value) for value in spec.command
        )
        lines.append(
            f'{command} 1>>"{stdout_path}" 2>>"{stderr_path}"'
        )
        return "\r\n".join(lines) + "\r\n"

    @staticmethod
    def _render_task_xml(spec: ServiceSpec, script_path: Path) -> str:
        from xml.sax.saxutils import escape

        restart = ""
        if spec.restart_policy in ("always", "on-failure"):
            restart = (
                "\n    <RestartOnFailure>\n"
                "      <Interval>PT1M</Interval>\n"
                "      <Count>999</Count>\n"
                "    </RestartOnFailure>"
            )
        return f'''<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>{escape(spec.description)}</Description></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>{restart}
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>cmd.exe</Command>
      <Arguments>/D /C &quot;{escape(str(script_path))}&quot;</Arguments>
      <WorkingDirectory>{escape(str(spec.working_directory))}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
'''

    @staticmethod
    def _run_schtasks(args: list[str], *, action: str, allow_absent: bool = False) -> str:
        from hermes_cli import gateway_windows

        code, stdout, stderr = gateway_windows._exec_schtasks(args)
        detail = stderr or stdout or ""
        if code != 0:
            absent = "cannot find" in detail.lower() or "not exist" in detail.lower()
            if not (allow_absent and absent):
                raise ManagedServiceCommandError("Windows Task Scheduler", action, detail)
        return stdout

    def install_service(
        self,
        spec: ServiceSpec,
        *,
        system: bool = False,
        start_now: bool = True,
    ) -> Path:
        if system:
            raise NotImplementedError("Windows managed services are installed per user")
        _prepare_service_paths(spec)
        script_path = self._script_path(spec.name)
        previous = script_path.read_bytes() if script_path.exists() else None
        was_running = previous is not None and self.is_service_running(spec.name)
        xml_path = script_path.with_suffix(".task.xml")
        task_created = False
        try:
            _atomic_write(script_path, self._render_script(spec))
            _atomic_write(
                xml_path,
                self._render_task_xml(spec, script_path).encode("utf-16"),
            )
            self._run_schtasks(
                ["/Create", "/F", "/TN", self._task_name(spec.name), "/XML", str(xml_path)],
                action=f"install {spec.name}",
            )
            task_created = True
            if start_now:
                if was_running:
                    self.stop_service(spec.name)
                self.start_service(spec.name)
        except Exception:
            if previous is None:
                script_path.unlink(missing_ok=True)
                if task_created:
                    try:
                        self._run_schtasks(
                            ["/Delete", "/F", "/TN", self._task_name(spec.name)],
                            action=f"roll back {spec.name}",
                            allow_absent=True,
                        )
                    except ManagedServiceCommandError:
                        pass
            else:
                _atomic_write(script_path, previous)
                if was_running:
                    try:
                        self.start_service(spec.name)
                    except ManagedServiceCommandError:
                        pass
            raise
        finally:
            xml_path.unlink(missing_ok=True)
        return script_path

    def uninstall_service(self, name: str, *, system: bool = False) -> None:
        if system:
            raise NotImplementedError("Windows managed services are installed per user")
        self._run_schtasks(
            ["/Delete", "/F", "/TN", self._task_name(name)],
            action=f"remove {name}",
            allow_absent=True,
        )
        self._script_path(name).unlink(missing_ok=True)

    def start_service(self, name: str, *, system: bool = False) -> None:
        if system:
            raise NotImplementedError("Windows managed services are installed per user")
        self._run_schtasks(
            ["/Run", "/TN", self._task_name(name)],
            action=f"start {name}",
        )

    def stop_service(self, name: str, *, system: bool = False) -> None:
        if system:
            raise NotImplementedError("Windows managed services are installed per user")
        self._run_schtasks(
            ["/End", "/TN", self._task_name(name)],
            action=f"stop {name}",
            allow_absent=True,
        )

    def restart_service(self, name: str, *, system: bool = False) -> None:
        self.stop_service(name, system=system)
        self.start_service(name, system=system)

    def is_service_running(self, name: str, *, system: bool = False) -> bool:
        if system:
            return False
        try:
            output = self._run_schtasks(
                ["/Query", "/TN", self._task_name(name), "/V", "/FO", "LIST"],
                action=f"query {name}",
            )
        except ManagedServiceCommandError:
            return False
        return bool(re.search(r"(?im)^\s*(status|state)\s*:\s*running\s*$", output))

    def is_service_installed(self, name: str, *, system: bool = False) -> bool:
        if system:
            return False
        try:
            self._run_schtasks(
                ["/Query", "/TN", self._task_name(name)],
                action=f"query {name}",
            )
        except ManagedServiceCommandError:
            return False
        return True

    def install(
        self,
        *,
        force: bool = False,
        start_now: bool | None = None,
        start_on_login: bool | None = None,
        elevated_handoff: bool = False,
    ) -> None:
        from hermes_cli import gateway_windows
        gateway_windows.install(
            force=force,
            start_now=start_now,
            start_on_login=start_on_login,
            elevated_handoff=elevated_handoff,
        )

    def start(self, name: str) -> None:
        from hermes_cli import gateway_windows
        gateway_windows.start()

    def stop(self, name: str) -> None:
        from hermes_cli import gateway_windows
        gateway_windows.stop()

    def restart(self, name: str) -> None:
        from hermes_cli import gateway_windows
        gateway_windows.restart()

    def is_running(self, name: str) -> bool:
        from hermes_cli import gateway_windows
        from hermes_cli.gateway import find_gateway_pids
        if not gateway_windows.is_installed():
            return False
        return bool(find_gateway_pids())


def get_service_manager() -> ServiceManager:
    """Return the ServiceManager instance for the current environment.

    Raises:
        RuntimeError: when no supported backend is available.
    """
    kind = detect_service_manager()
    if kind == "systemd":
        return SystemdServiceManager()
    if kind == "launchd":
        return LaunchdServiceManager()
    if kind == "windows":
        return WindowsServiceManager()
    if kind == "s6":
        return S6ServiceManager()
    raise RuntimeError("no supported service manager detected")


# ---------------------------------------------------------------------------
# S6ServiceManager (container-only)
#
# Per-profile gateways are registered dynamically when `hermes profile create`
# runs inside the container (Phase 4). Static services (main-hermes, dashboard)
# live in /etc/s6-overlay/s6-rc.d/ and are NOT managed by this class — they're
# part of the image, not runtime-created.
# ---------------------------------------------------------------------------


# s6-overlay's dynamic scandir for runtime-registered services. Lives on
# tmpfs and is the directory s6-svscan watches. Writes here trigger
# automatic supervision on the next rescan.
S6_DYNAMIC_SCANDIR = Path("/run/service")
S6_SERVICE_PREFIX = "gateway-"


def _profile_dir_for_gateway_service(name: str) -> Path:
    """Resolve ``gateway-<profile>`` to its persistent profile directory.

    s6 lifecycle commands may be invoked from any active profile, including
    ``gateway stop --all``. Do not write the caller's HERMES_HOME blindly;
    derive the shared profile root from the current HERMES_HOME and map the
    service suffix to either the root default profile or
    ``<root>/profiles/<profile>``.
    """
    import os

    profile = name[len(S6_SERVICE_PREFIX):] if name.startswith(S6_SERVICE_PREFIX) else name
    validate_profile_name(profile)
    hermes_home = Path(os.environ.get("HERMES_HOME", "/opt/data"))
    if hermes_home.parent.name == "profiles":
        root = hermes_home.parent.parent
    else:
        root = hermes_home
    return root if profile == "default" else root / "profiles" / profile


def _write_gateway_desired_state(name: str, desired_state: str) -> None:
    """Persist durable s6 gateway intent next to runtime status.

    ``gateway_state`` remains the volatile runtime field written by the
    gateway process. ``desired_state`` records the operator's start/stop
    intent so container-boot reconciliation can restore the correct s6
    want-up/want-down state after pod recreation even if the previous runtime
    state was transient (draining, startup_failed, etc.). The write is
    best-effort: a failed persistence attempt must not prevent immediate s6
    lifecycle control.
    """
    import json
    import time

    profile_dir = _profile_dir_for_gateway_service(name)
    state_file = profile_dir / "gateway_state.json"
    try:
        if not profile_dir.exists():
            return
        try:
            data = json.loads(state_file.read_text()) if state_file.exists() else {}
            if not isinstance(data, dict):
                data = {}
        except (OSError, json.JSONDecodeError):
            data = {}
        data["desired_state"] = desired_state
        data["updated_at"] = int(time.time())
        tmp = state_file.with_suffix(state_file.suffix + ".tmp")
        tmp.write_text(json.dumps(data, separators=(",", ":")) + "\n")
        tmp.replace(state_file)
    except OSError:
        return


# s6-overlay installs its binaries under /command/ and only adds that
# directory to PATH for processes started under the supervision tree
# (services started by s6-svscan, cont-init.d scripts, etc.). Code
# that runs via `docker exec` or any other out-of-tree entry point —
# notably our Phase 4 profile create/delete hooks — inherits the
# container's base PATH which does NOT include /command/.
#
# Rather than asking every caller to fix up its environment, the
# S6ServiceManager calls s6-* binaries by absolute path via this
# constant. We don't use `/usr/bin/s6-…` symlinks because the
# s6-overlay-symlinks-noarch tarball only links a subset, and we
# want every s6 invocation to be guaranteed-findable.
_S6_BIN_DIR = "/command"


# UID/GID of the in-image ``hermes`` user. Hardcoded to match what
# ``stage2-hook.sh`` enforces (the runtime invariant — see also
# tests/docker/test_uid_remap.py). The container starts s6-supervise
# under root and immediately drops to this UID via ``s6-setuidgid``.
_HERMES_UID = 10000
_HERMES_GID = 10000


def _seed_supervise_skeleton(svc_dir: Path) -> None:
    """Pre-create the ``supervise/`` and top-level ``event/`` skeleton
    inside a service directory, owned by the hermes user.

    Why this exists
    ---------------
    When s6-supervise spawns a service it tries to ``mkdir`` two
    directories: ``<svc>/event`` and ``<svc>/supervise``, both with mode
    ``0700``. It also ``mkfifo``s ``<svc>/supervise/control`` with mode
    ``0600``. Because s6-supervise runs as PID 1's effective UID (root)
    these dirs end up root-owned mode 0700, and an unprivileged client
    (the ``hermes`` user — UID 10000 — running every Hermes runtime
    operation via ``s6-setuidgid``) gets ``EACCES`` on any ``s6-svc``,
    ``s6-svstat``, or ``s6-svwait`` invocation against the slot.

    The PR #30136 review surfaced this as a real product gap: the
    entire S6ServiceManager lifecycle (``register/start/stop/unregister
    _profile_gateway``) was inert in production because every operation
    is dispatched as the hermes user.

    Why this works
    --------------
    Reading s6's source (src/supervision/s6-supervise.c::trymkdir +
    control_init): the ``mkdir`` and ``mkfifo`` calls both treat
    ``EEXIST`` as success. If the directory is already present, the
    chown/chmod fix-up that would normally make event/ ``03730
    root:root`` is **skipped** entirely — s6-supervise just opens the
    pre-existing FIFOs and proceeds. So if we lay the skeleton down
    with hermes ownership before triggering ``s6-svscanctl -a``,
    s6-supervise inherits our layout and never touches it.

    Layout produced
    ---------------
    ``svc_dir/``                           hermes:hermes, 0755 (parent must already exist)
    ``svc_dir/event/``                     hermes:hermes, 03730   (setgid + g+rwx + sticky)
    ``svc_dir/supervise/``                 hermes:hermes, 0755
    ``svc_dir/supervise/event/``           hermes:hermes, 03730
    ``svc_dir/supervise/control``          hermes:hermes, 0660    (FIFO)

    The ``death_tally``, ``lock``, and ``status`` regular files end up
    written by s6-supervise itself (as root), but those land mode 0644 —
    world-readable — and ``s6-svstat`` only needs read access, so the
    hermes user reads them fine.

    If ``svc_dir/log/`` is present (the canonical s6 logger pattern —
    one s6-supervise instance per service, plus a second for its
    logger), the same skeleton is seeded under ``log/`` as well:
    ``log/event/``, ``log/supervise/``, ``log/supervise/event/``,
    ``log/supervise/control``. Without this, unregister teardown
    would EACCES on the logger's supervise dir even after the parent
    slot's supervise/ was hermes-owned.

    Idempotency
    -----------
    Safe to call against a directory where the skeleton already exists.
    Existing entries are left untouched (the helper doesn't try to
    re-chown / re-chmod live FIFOs that s6-supervise may have already
    opened).

    Reference
    ---------
    Discussed at length on the skarnet `skaware` mailing list in 2020
    (`<http://skarnet.org/lists/skaware/1424.html>`_); see also
    just-containers/s6-overlay#130. The pre-creation pattern was
    historically called out as forward-compatibility-fragile, but the
    EEXIST handling in s6-supervise has been stable since 2015 — it's
    the same pattern ``s6-svperms`` and ``fix-attrs.d`` rely on.
    """
    import os

    def _mkdir_owned(path: Path, mode: int) -> None:
        if path.exists():
            return
        path.mkdir(parents=False, exist_ok=False)
        try:
            os.chown(path, _HERMES_UID, _HERMES_GID)
        except PermissionError:
            # Running as the hermes user already — directory is hermes-
            # owned by default. The chown is a no-op in that case, so
            # swallowing this keeps both root and unprivileged callers
            # on one code path.
            # Development hosts can create temp directories in a group the
            # current user does not belong to (notably wheel on macOS), which
            # makes the kernel silently clear setgid during chmod. Normalize
            # to the caller's primary group in that non-root fallback.
            try:
                os.chown(path, -1, os.getgid())
            except PermissionError:
                pass
        # chown may clear setgid/sticky bits on some hosts; apply the
        # intended permissions only after ownership is settled.
        path.chmod(mode)

    # Top-level event/ dir (this is the s6-svlisten1 event-subscription
    # dir at the service root, distinct from supervise/event/).
    _mkdir_owned(svc_dir / "event", 0o3730)

    # supervise/ dir + its inner event/ dir.
    supervise = svc_dir / "supervise"
    _mkdir_owned(supervise, 0o755)
    _mkdir_owned(supervise / "event", 0o3730)

    # supervise/control FIFO. Same EEXIST-safe pattern: if it's already
    # there (s6-supervise has already started against this slot), leave
    # it alone. The explicit chmod after mkfifo is required because
    # mkfifo honors the process umask, which can strip group-write
    # (e.g. the default 0022 on most dev hosts → 0o660 becomes 0o640).
    # The container runs with umask 0 inside s6-overlay's stage2, but
    # being defensive here keeps the helper consistent under any
    # invocation context.
    control = supervise / "control"
    if not control.exists():
        os.mkfifo(control, 0o660)
        try:
            os.chown(control, _HERMES_UID, _HERMES_GID)
        except PermissionError:
            pass
        control.chmod(0o660)

    # If a log/ subdir is present (the canonical s6 logger pattern —
    # see servicedir(7)), it gets its own s6-supervise instance and
    # needs the same skeleton. Without this, unregister teardown
    # would EACCES on the logger's root-owned supervise/ dir even
    # when the parent slot's supervise/ is hermes-owned.
    log_dir = svc_dir / "log"
    if log_dir.is_dir():
        _mkdir_owned(log_dir / "event", 0o3730)
        log_supervise = log_dir / "supervise"
        _mkdir_owned(log_supervise, 0o755)
        _mkdir_owned(log_supervise / "event", 0o3730)
        log_control = log_supervise / "control"
        if not log_control.exists():
            os.mkfifo(log_control, 0o660)
            try:
                os.chown(log_control, _HERMES_UID, _HERMES_GID)
            except PermissionError:
                pass
            log_control.chmod(0o660)


class S6Error(RuntimeError):
    """Base error for S6ServiceManager lifecycle failures.

    Concrete subclasses carry the slot name (and, where useful, the
    underlying subprocess output) so the CLI can render an actionable
    message instead of leaking a raw ``CalledProcessError`` traceback.
    """

    def __init__(self, message: str, *, service: str | None = None) -> None:
        super().__init__(message)
        self.service = service


class GatewayNotRegisteredError(S6Error):
    """Raised when a lifecycle method targets a slot that doesn't exist.

    Most commonly: ``hermes -p typo gateway start`` when no profile
    ``typo`` exists. Carries the unprefixed profile name (not the
    full ``gateway-<profile>`` service-dir name) so callers can phrase
    a user-facing message like "no such gateway 'typo'".
    """

    def __init__(self, profile: str) -> None:
        self.profile = profile
        super().__init__(
            f"no such gateway {profile!r}: register it with "
            f"`hermes profile create {profile}` first, or pass "
            "an existing profile name via `-p <name>`",
            service=f"gateway-{profile}",
        )


class S6CommandError(S6Error):
    """Raised when an s6 command fails for a reason other than a
    missing slot — e.g. permission denied on the supervise control
    FIFO, or s6-svc returning a non-zero exit for an unexpected
    reason. Carries the stderr from the failing command so callers
    can surface it.
    """

    def __init__(
        self, *, service: str, action: str, returncode: int, stderr: str,
    ) -> None:
        self.action = action
        self.returncode = returncode
        self.stderr = stderr
        message = (
            f"s6-svc {action} on {service!r} failed (rc={returncode})"
        )
        if stderr.strip():
            message += f": {stderr.strip()}"
        super().__init__(message, service=service)


class S6ServiceManager:
    """Per-profile gateway supervision via s6-overlay.

    Only handles runtime-registered services under
    ``S6_DYNAMIC_SCANDIR``. Static services (main-hermes, dashboard)
    are managed by s6-rc at image-build time and are out of scope.
    """

    kind: ServiceManagerKind = "s6"

    def __init__(self, scandir: Path = S6_DYNAMIC_SCANDIR) -> None:
        self.scandir = scandir

    # -- internal helpers --------------------------------------------------

    def _service_dir(self, profile: str) -> Path:
        validate_profile_name(profile)
        return self.scandir / f"{S6_SERVICE_PREFIX}{profile}"

    def _service_name(self, profile: str) -> str:
        return f"{S6_SERVICE_PREFIX}{profile}"

    @staticmethod
    def _render_managed_run_script(spec: ServiceSpec) -> str:
        lines = [
            "#!/command/with-contenv sh",
            "# shellcheck shell=sh",
            "set -eu",
            "umask 077",
            f"cd {shlex.quote(str(spec.working_directory))}",
        ]
        for key, value in sorted(spec.environment.items()):
            lines.append(f"export {key}={shlex.quote(value)}")
        command = shlex.join(list(spec.command))
        lines.append(
            f"exec {command} >>{shlex.quote(str(spec.stdout_path))} "
            f"2>>{shlex.quote(str(spec.stderr_path))}"
        )
        return "\n".join(lines) + "\n"

    @staticmethod
    def _render_managed_finish_script(spec: ServiceSpec) -> str:
        if spec.restart_policy == "always":
            body = "exit 0"
        elif spec.restart_policy == "never":
            body = "exit 125"
        else:
            body = '[ "$1" = "0" ] && exit 125\nexit 0'
        return (
            "#!/command/with-contenv sh\n"
            "# $1 is the service exit code; 125 tells s6 not to restart.\n"
            f"{body}\n"
        )

    def install_service(
        self,
        spec: ServiceSpec,
        *,
        system: bool = False,
        start_now: bool = True,
    ) -> Path:
        """Atomically install or reconcile an s6 longrun service."""
        import shutil

        if system:
            raise NotImplementedError("s6 uses its active scandir, not system scope")
        _prepare_service_paths(spec)
        validate_service_name(spec.name)
        self.scandir.mkdir(parents=True, exist_ok=True)
        service_dir = self.scandir / spec.name
        staging = self.scandir / f".{spec.name}.tmp"
        backup = self.scandir / f".{spec.name}.backup"
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        if backup.exists():
            shutil.rmtree(backup, ignore_errors=True)
        had_existing = service_dir.exists()
        prior_should_run = had_existing and not (service_dir / "down").exists()
        prior_stopped = False
        staging.mkdir()
        try:
            (staging / "type").write_text("longrun\n", encoding="utf-8")
            run_path = staging / "run"
            run_path.write_text(self._render_managed_run_script(spec), encoding="utf-8")
            run_path.chmod(0o755)
            finish_path = staging / "finish"
            finish_path.write_text(
                self._render_managed_finish_script(spec),
                encoding="utf-8",
            )
            finish_path.chmod(0o755)
            if not start_now:
                (staging / "down").touch()
            _seed_supervise_skeleton(staging)

            if service_dir.exists():
                _run_managed_command(
                    [f"{_S6_BIN_DIR}/s6-svc", "-d", str(service_dir)],
                    manager="s6",
                    action=f"stop prior {spec.name}",
                )
                prior_stopped = True
                _run_managed_command(
                    [
                        f"{_S6_BIN_DIR}/s6-svwait",
                        "-D",
                        "-t",
                        "10000",
                        str(service_dir),
                    ],
                    manager="s6",
                    action=f"wait for prior {spec.name} to stop",
                )
                service_dir.rename(backup)
            staging.rename(service_dir)
            try:
                _run_managed_command(
                    [f"{_S6_BIN_DIR}/s6-svscanctl", "-a", str(self.scandir)],
                    manager="s6",
                    action=f"install {spec.name}",
                )
            except Exception:
                shutil.rmtree(service_dir, ignore_errors=True)
                if backup.exists():
                    backup.rename(service_dir)
                    subprocess.run(
                        [f"{_S6_BIN_DIR}/s6-svscanctl", "-a", str(self.scandir)],
                        check=False,
                        capture_output=True,
                        timeout=5,
                    )
                raise
            shutil.rmtree(backup, ignore_errors=True)
        except Exception:
            shutil.rmtree(staging, ignore_errors=True)
            # A failure before or during the atomic swap must leave the exact
            # prior directory registered and restore its former up-state.
            if backup.exists() and not service_dir.exists():
                try:
                    backup.rename(service_dir)
                    subprocess.run(
                        [f"{_S6_BIN_DIR}/s6-svscanctl", "-a", str(self.scandir)],
                        check=False,
                        capture_output=True,
                        timeout=5,
                    )
                except OSError:
                    pass
            if prior_stopped and prior_should_run and service_dir.exists():
                subprocess.run(
                    [f"{_S6_BIN_DIR}/s6-svc", "-u", str(service_dir)],
                    check=False,
                    capture_output=True,
                    timeout=5,
                )
            raise
        return service_dir

    def uninstall_service(self, name: str, *, system: bool = False) -> None:
        import shutil

        if system:
            raise NotImplementedError("s6 uses its active scandir, not system scope")
        validate_service_name(name)
        service_dir = self.scandir / name
        if not service_dir.exists():
            return
        _run_managed_command(
            [f"{_S6_BIN_DIR}/s6-svc", "-d", str(service_dir)],
            manager="s6",
            action=f"stop {name} before uninstall",
        )
        _run_managed_command(
            [f"{_S6_BIN_DIR}/s6-svwait", "-D", "-t", "10000", str(service_dir)],
            manager="s6",
            action=f"wait for {name} to stop before uninstall",
        )
        tombstone = self.scandir / f".{name}.removing"
        if tombstone.exists():
            shutil.rmtree(tombstone, ignore_errors=True)
        service_dir.rename(tombstone)
        try:
            _run_managed_command(
                [f"{_S6_BIN_DIR}/s6-svscanctl", "-an", str(self.scandir)],
                manager="s6",
                action=f"unregister {name}",
            )
        except Exception:
            tombstone.rename(service_dir)
            raise
        shutil.rmtree(tombstone, ignore_errors=True)

    def start_service(self, name: str, *, system: bool = False) -> None:
        if system:
            raise NotImplementedError("s6 uses its active scandir, not system scope")
        validate_service_name(name)
        (self.scandir / name / "down").unlink(missing_ok=True)
        self._run_svc("-u", "start", name)

    def stop_service(self, name: str, *, system: bool = False) -> None:
        if system:
            raise NotImplementedError("s6 uses its active scandir, not system scope")
        validate_service_name(name)
        self._run_svc("-d", "stop", name)
        (self.scandir / name / "down").touch()

    def restart_service(self, name: str, *, system: bool = False) -> None:
        if system:
            raise NotImplementedError("s6 uses its active scandir, not system scope")
        validate_service_name(name)
        self._run_svc("-t", "restart", name)

    def is_service_running(self, name: str, *, system: bool = False) -> bool:
        if system:
            return False
        validate_service_name(name)
        return self.is_running(name)

    def is_service_installed(self, name: str, *, system: bool = False) -> bool:
        if system:
            return False
        validate_service_name(name)
        return (self.scandir / name).is_dir()

    @staticmethod
    def _render_run_script(
        profile: str,
        extra_env: dict[str, str],
    ) -> str:
        """Generate the run script for a profile-gateway s6 service.

        The script:
          1. Sources HERMES_HOME (and any extra env) via with-contenv —
             so e.g. ``-e HERMES_HOME=/data/hermes`` is honored at run
             time, not Python-substituted at registration time (OQ8-C).
          2. Resets ``HOME`` to ``/opt/data`` before the privilege drop
             so with-contenv's root HOME does not leak into the
             unprivileged gateway process.
          3. Activates the bundled venv.
          4. Drops to the hermes user and exec's
             ``hermes -p <profile> gateway run`` (or just ``hermes
             gateway run`` for the default profile — see below).

        Special case: ``profile == "default"`` emits ``hermes gateway
        run`` with **no** ``-p`` flag. This is the sentinel for "the
        root HERMES_HOME profile" (the implicit profile that exists at
        the top of $HERMES_HOME, not under profiles/). It must be
        spelled this way because ``_profile_suffix()`` returns the
        empty string for the root profile, and the dispatcher in
        ``hermes_cli.gateway`` maps that empty string to the
        ``gateway-default`` service slot. Passing ``-p default`` here
        would instead look up ``$HERMES_HOME/profiles/default/`` — a
        completely different (and almost always nonexistent) profile.

        Port selection: the gateway binds the port resolved by
        ``gateway/config.py`` from the profile's own environment —
        ``API_SERVER_PORT`` (or ``platforms.api_server.extra.port`` in
        that profile's ``config.yaml``), defaulting to 8642. There is
        no ``[gateway] port`` key and no Python-side allocator: because
        each supervised profile gateway loads its own ``HERMES_HOME``,
        two profiles that both leave the port unset will both try to
        bind 8642 — give each profile a distinct ``API_SERVER_PORT`` in
        its ``.env``. Previously this method took a ``port`` parameter
        that was passed in but never substituted into the rendered
        script (carried for "API parity" with a deterministic SHA-256
        allocator in ``hermes_cli.profiles._allocate_gateway_port``).
        PR #30136 review item I5 retired both the allocator and the
        parameter because they were dead code through the entire stack.
        """
        import shlex
        lines = [
            "#!/command/with-contenv sh",
            "# shellcheck shell=sh",
            "set -e",
            "export HOME=/opt/data",
            "cd /opt/data",
            ". /opt/hermes/.venv/bin/activate",
        ]
        for k, v in sorted(extra_env.items()):
            lines.append(f"export {k}={shlex.quote(v)}")
        # Sentinel for the supervised-child path. Prevents recursive
        # redirect when the supervised gateway re-enters
        # `_gateway_command_inner` with subcmd == "run" — without it the
        # supervisor would dispatch `gateway start` which would re-exec
        # `gateway run --replace` which would re-dispatch `gateway
        # start`, etc. See `_gateway_command_inner` for the matching
        # guard.
        lines.append("export HERMES_S6_SUPERVISED_CHILD=1")
        # ``--replace`` makes the supervised gateway authoritative for its
        # profile's HERMES_HOME. Without it, a gateway started OUTSIDE s6
        # (a stray ``hermes gateway run`` from a shell, an agent action, or
        # the Open WebUI helper) grabs the per-HERMES_HOME PID lock first;
        # the supervised slot then execs a bare ``gateway run``, hits the
        # "Another gateway instance is already running" guard, exits
        # non-zero, and s6 restarts it — a restart loop that floods the
        # log and never binds (NS-505). ``--replace``
        # instead reaps the stale holder (hardened takeover path: marker +
        # SIGTERM→SIGKILL-with-confirmation + scoped-lock cleanup, see
        # gateway/run.py) so s6 always wins. The HERMES_S6_SUPERVISED_CHILD
        # sentinel above prevents the run→start→run redirect recursion.
        # Each profile is scoped to its own HERMES_HOME and s6 guarantees a
        # single supervised instance per slot, so there is no legitimate
        # supervised sibling for ``--replace`` to clobber.
        if profile == "default":
            gateway_cmd = "hermes gateway run --replace"
        else:
            gateway_cmd = f"hermes -p {shlex.quote(profile)} gateway run --replace"
        # Skip the drop when already non-root (setgroups() lacks CAP_SETGID →
        # s6 boot-loop).
        lines.append(f'[ "$(id -u)" = 0 ] || exec {gateway_cmd}')
        lines.append(f"exec s6-setuidgid hermes {gateway_cmd}")
        return "\n".join(lines) + "\n"

    @staticmethod
    def _render_finish_script() -> str:
        """Generate the finish script for a profile-gateway s6 service.

        When the gateway exits with EX_CONFIG (78) — a fatal
        configuration error such as a token collision or no messaging
        platforms — we tell s6-supervise to stop restarting by exiting
        125 (permanent failure).  Any other exit code lets s6 restart
        normally.  See #51228.
        """
        from gateway.restart import GATEWAY_FATAL_CONFIG_EXIT_CODE

        code = GATEWAY_FATAL_CONFIG_EXIT_CODE
        return (
            "#!/command/with-contenv sh\n"
            "# shellcheck shell=sh\n"
            "# $1 = exit code from the run script.\n"
            f"# Exit {code} (EX_CONFIG) = fatal config error — don't restart.\n"
            f'if [ "$1" = "{code}" ]; then\n'
            "  exit 125\n"
            "fi\n"
            "exit 0\n"
        )

    @staticmethod
    def _render_log_run(profile: str) -> str:
        """Generate the log/run script for a profile-gateway service.

        OQ8-C: persist to ``${HERMES_HOME}/logs/gateways/<profile>/``.
        CRITICAL: the HERMES_HOME path is sourced from the runtime env
        via with-contenv — NOT Python-substituted at registration time
        — so a container started with ``-e HERMES_HOME=/data/hermes``
        gets its logs under /data/hermes/logs/..., not the build-time
        default.

        Output routing — the script is two action directives, applied
        per line, in order:

          1. ``1`` (forward to stdout) — propagates the line up the
             s6-supervise pipeline to /init's stdout, which is the
             container's stdout, which is ``docker logs``. Without
             this, supervised stdout would be terminated inside
             s6-log and never reach the container's log stream;
             users would have to ``docker exec`` and ``tail`` the
             file just to see startup banners. (Python's ``logging``
             module defaults to stderr, which s6-supervise leaves
             unfiltered — so warnings/errors already reach docker
             logs. This change is specifically about the rich-console
             banner output and other plain stdout writes.)
          2. ``T <log_dir>`` — also write a timestamped copy to the
             rotated log directory (``current`` + archived ``@*.s``
             files). This is what ``hermes logs`` reads and what
             persists across container restarts via the volume mount.

        ``T`` is non-sticky: it only prefixes lines for the next
        action directive. We deliberately put ``T`` between ``1``
        and the log dir (not before ``1``) so:

          * ``docker logs`` shows raw lines — Python's logging
            formatter has its own timestamps, and ``docker logs
            --timestamps`` adds a third layer when desired. No
            double-stamping in the most common reading path.
          * The persisted file gets s6-log's own ISO 8601 timestamp
            so even output that lacked a Python-logger timestamp
            (rich banners, third-party libs' raw prints) is
            correlatable in ``current``.
        """
        import shlex
        prof = shlex.quote(profile)
        return (
            f"#!/command/with-contenv sh\n"
            f"# shellcheck shell=sh\n"
            f': "${{HERMES_HOME:=/opt/data}}"\n'
            f'log_dir="$HERMES_HOME/logs/gateways/{prof}"\n'
            f'mkdir -p "$log_dir"\n'
            # The gateways/ parent must be chowned too (non-recursively):
            # `mkdir -p` creates it root-owned on a root-context boot, and a
            # leaf-only chown leaves it that way — every profile registered
            # later then runs its log service as hermes and crash-loops on
            # `mkdir: Permission denied`. The parent chown runs on every
            # root-context boot, so it also heals volumes already poisoned
            # by older images. Non-recursive on purpose: sibling profile
            # dirs are each managed by their own log/run. See #45258.
            f'chown hermes:hermes "$HERMES_HOME/logs/gateways" 2>/dev/null || true\n'
            f'chown -R hermes:hermes "$log_dir" 2>/dev/null || true\n'
            f'rm -f "$log_dir/lock"\n'
            # Skip the drop when already non-root (CAP_SETGID).
            f'[ "$(id -u)" = 0 ] || exec s6-log 1 n10 s1000000 T "$log_dir"\n'
            f'exec s6-setuidgid hermes s6-log 1 n10 s1000000 T "$log_dir"\n'
        )

    # -- lifecycle ---------------------------------------------------------

    def _run_svc(self, action_flag: str, action_label: str, name: str) -> None:
        """Shared lifecycle dispatch for start / stop / restart.

        Translates the two failure modes operators care about into
        named errors:

        * ``GatewayNotRegisteredError`` — the service directory at
          ``<scandir>/<name>/`` doesn't exist. ``s6-svc`` would
          exit non-zero with a fairly opaque message; we pre-empt
          it with a clear "no such gateway 'X'" tied to the profile
          name (without the ``gateway-`` prefix).
        * ``S6CommandError`` — anything else (EACCES on the
          supervise control FIFO, timeout, etc.). Carries the
          subprocess return code and stderr so callers can render
          them inline.

        ``action_flag`` is the ``s6-svc`` flag (``-u`` / ``-d`` /
        ``-t``); ``action_label`` is the human verb (``start`` /
        ``stop`` / ``restart``) used in error messages.
        """
        import subprocess

        service_dir = self.scandir / name
        if not service_dir.is_dir():
            # Strip the gateway- prefix back off so the message
            # matches what the user typed on the CLI (``-p <profile>``).
            profile = (
                name[len(S6_SERVICE_PREFIX):]
                if name.startswith(S6_SERVICE_PREFIX)
                else name
            )
            raise GatewayNotRegisteredError(profile)

        try:
            subprocess.run(
                [f"{_S6_BIN_DIR}/s6-svc", action_flag, str(service_dir)],
                check=True, capture_output=True, text=True, timeout=5,
            )
        except subprocess.CalledProcessError as exc:
            raise S6CommandError(
                service=name,
                action=action_label,
                returncode=exc.returncode,
                stderr=exc.stderr or "",
            ) from exc

    def start(self, name: str) -> None:
        """Bring up a registered service (``s6-svc -u``).

        Raises:
            GatewayNotRegisteredError: no service directory for ``name``.
            S6CommandError: s6-svc exited non-zero for any other reason
                (permission denied on the supervise FIFO, timeout, etc.).
        """
        self._run_svc("-u", "start", name)
        _write_gateway_desired_state(name, "running")

    def _supervised_pid(self, name: str) -> int | None:
        """Return the PID of the supervised gateway process, or None.

        Parses ``s6-svstat`` output (``up (pid NNNN) ...``). Used to
        mark an operator-initiated stop with the planned-stop marker so
        the gateway's shutdown handler classifies the incoming SIGTERM
        as intentional rather than an unexpected kill (issue #42675).
        Best-effort: any parse/exec failure returns None.
        """
        import subprocess

        try:
            result = subprocess.run(
                [f"{_S6_BIN_DIR}/s6-svstat", str(self.scandir / name)],
                capture_output=True, text=True, timeout=5,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if result.returncode != 0:
            return None
        m = re.search(r"\(pid (\d+)\)", result.stdout)
        return int(m.group(1)) if m else None

    def stop(self, name: str) -> None:
        """Bring down a registered service (``s6-svc -d``).

        Writes a planned-stop marker naming the supervised gateway PID
        BEFORE sending the down command, so the gateway's shutdown
        handler recognises this SIGTERM as an operator-initiated stop
        and persists ``gateway_state=stopped`` (respecting the explicit
        intent). Without the marker, an intentional ``hermes gateway
        stop`` is indistinguishable from the container/s6 SIGTERM sent on
        ``docker restart``; the latter must NOT persist ``stopped`` or
        container_boot refuses to auto-start on the next boot (#42675).
        The marker write is best-effort — a failure only means the stop
        is treated as signal-initiated, which is the safe fallback.

        Raises:
            GatewayNotRegisteredError: no service directory for ``name``.
            S6CommandError: s6-svc exited non-zero for any other reason.
        """
        pid = self._supervised_pid(name)
        if pid is not None:
            try:
                from gateway.status import write_planned_stop_marker

                write_planned_stop_marker(pid)
            except Exception:
                pass
        self._run_svc("-d", "stop", name)
        _write_gateway_desired_state(name, "stopped")

    def restart(self, name: str) -> None:
        """Restart a registered service (``s6-svc -t`` = SIGTERM).

        Raises:
            GatewayNotRegisteredError: no service directory for ``name``.
            S6CommandError: s6-svc exited non-zero for any other reason.
        """
        self._run_svc("-t", "restart", name)
        _write_gateway_desired_state(name, "running")

    def is_running(self, name: str) -> bool:
        """True iff ``s6-svstat`` reports the service as up."""
        import subprocess
        result = subprocess.run(
            [f"{_S6_BIN_DIR}/s6-svstat", str(self.scandir / name)],
            capture_output=True, text=True, timeout=5,
        )
        return result.returncode == 0 and "up " in result.stdout

    # -- runtime registration ---------------------------------------------

    def supports_runtime_registration(self) -> bool:
        return True

    def register_profile_gateway(
        self,
        profile: str,
        *,
        extra_env: dict[str, str] | None = None,
        start_now: bool = True,
    ) -> None:
        """Create the s6 service directory for a profile gateway.

        Triggers ``s6-svscanctl -a`` so s6-svscan picks the new directory
        up immediately.  When *start_now* is ``True`` (the default) the
        service starts immediately; when ``False`` a ``down`` marker file
        is written so s6-supervise leaves the service stopped until the
        user explicitly runs ``hermes -p <profile> gateway start``.

        Raises:
            ValueError: if the profile name is invalid or the service
                directory already exists.
            RuntimeError: if ``s6-svscanctl`` fails.
        """
        import shutil
        import subprocess

        svc_dir = self._service_dir(profile)
        if svc_dir.exists():
            raise ValueError(
                f"profile gateway {profile!r} already registered at {svc_dir}"
            )

        # Build the service directory atomically: write to a sibling
        # temp dir, then rename. The staging name is DOT-PREFIXED
        # (``.gateway-<profile>.tmp``) so s6-svscan ignores it while it
        # is half-built: s6-svscan skips any scandir entry whose name
        # begins with ``.``. Without the dot prefix, a concurrent
        # ``s6-svscanctl -a`` rescan (fired by the cont-init reconciler
        # registering ``gateway-default``, or by a sibling register)
        # would supervise the still-being-seeded ``.tmp`` slot: it has a
        # valid ``type``/``run`` by that point, so s6-supervise spawns
        # AS ROOT and mkdir's ``supervise/`` root-owned 0700 — then this
        # process's ``_seed_supervise_skeleton`` early-returns on the now-
        # existing ``supervise/`` and the next ``mkdir supervise/event``
        # hits EACCES. That is the arm64-only CI flake on
        # test_s6_unregister_removes_service_dir_in_live_container
        # (the wider scheduling jitter on the native arm64 runner lets the
        # rescan land inside the ~ms seed window). The atomic rename to
        # the dotless live name below is unaffected.
        tmp_dir = svc_dir.with_name("." + svc_dir.name + ".tmp")
        if tmp_dir.exists():
            shutil.rmtree(tmp_dir, ignore_errors=True)
        tmp_dir.mkdir(parents=True)

        try:
            (tmp_dir / "type").write_text("longrun\n")

            run_script = self._render_run_script(profile, extra_env or {})
            run_path = tmp_dir / "run"
            run_path.write_text(run_script)
            run_path.chmod(0o755)

            finish_path = tmp_dir / "finish"
            finish_path.write_text(self._render_finish_script())
            finish_path.chmod(0o755)

            # Persistent log rotation (OQ8-C).
            log_subdir = tmp_dir / "log"
            log_subdir.mkdir()
            log_run = log_subdir / "run"
            log_run.write_text(self._render_log_run(profile))
            log_run.chmod(0o755)

            # Pre-create the supervise/ skeleton with hermes ownership
            # BEFORE we publish the slot. s6-supervise will EEXIST our
            # dirs/FIFOs and inherit the ownership, so the runtime
            # s6-svc / s6-svstat / s6-svwait calls (all dispatched as
            # the hermes user) won't hit EACCES on root-owned 0700
            # dirs. See ``_seed_supervise_skeleton`` for the full
            # rationale.
            _seed_supervise_skeleton(tmp_dir)

            # When start_now is False, write a `down` marker so
            # s6-supervise does not auto-start the service on rescan.
            # Mirrors the same pattern in container_boot.py
            # _register_gateway_slot when start=False.
            if not start_now:
                (tmp_dir / "down").touch()

            tmp_dir.rename(svc_dir)
        except Exception:
            shutil.rmtree(tmp_dir, ignore_errors=True)
            raise

        # Trigger rescan so s6-svscan picks up the new service.
        result = subprocess.run(
            [f"{_S6_BIN_DIR}/s6-svscanctl", "-a", str(self.scandir)],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            # Clean up: rescan failed, leave the directory in place would
            # be confusing (no supervisor watching it).
            shutil.rmtree(svc_dir, ignore_errors=True)
            raise RuntimeError(
                f"s6-svscanctl failed: {result.stderr or result.stdout}"
            )

    def unregister_profile_gateway(self, profile: str) -> None:
        """Stop the profile gateway service and remove its directory.

        Idempotent: absent services are a no-op. Best-effort stop +
        wait-for-down before removal so the running gateway process
        gets a chance to shut down cleanly before its service dir
        disappears.

        Teardown ordering matters: ``s6-svscanctl -an`` is fired
        **before** ``rmtree`` so s6-svscan reaps the supervise child
        process (releasing its handle on ``supervise/lock`` and the
        regular files inside the supervise dir), giving us a clean
        directory to remove. Without the reap-first ordering, the
        rmtree races s6-supervise on a set of root-owned files inside
        the supervise dir and the dir is left half-removed.
        """
        import shutil
        import subprocess
        import time

        svc_dir = self._service_dir(profile)
        if not svc_dir.exists():
            return

        # Stop the service (best effort — service may already be down).
        subprocess.run(
            [f"{_S6_BIN_DIR}/s6-svc", "-d", str(svc_dir)],
            capture_output=True, text=True, timeout=5,
            check=False,
        )
        # Wait for it to actually go down (up to 10s).
        subprocess.run(
            [f"{_S6_BIN_DIR}/s6-svwait", "-D", "-t", "10000", str(svc_dir)],
            capture_output=True, text=True, timeout=15,
            check=False,
        )

        # Reap the supervise child FIRST: -n tells s6-svscan to drop
        # any supervise processes whose service dir is gone (which
        # includes any service dir we're about to remove). This
        # releases the file handles s6-supervise holds against the
        # supervise/lock + supervise/status + supervise/death_tally
        # files inside the slot, so the upcoming rmtree doesn't race.
        subprocess.run(
            [f"{_S6_BIN_DIR}/s6-svscanctl", "-an", str(self.scandir)],
            capture_output=True, text=True, timeout=5,
            check=False,
        )
        # Give s6-svscan a moment to reap. There's no synchronous
        # "scan completed" handshake — the -a/-n trigger just sets a
        # flag s6-svscan reads on its next loop iteration. 200ms is
        # comfortably above the loop's resolution but well under any
        # user-perceived latency.
        time.sleep(0.2)

        # Now the supervise dir's files are no longer held open by a
        # live s6-supervise, so rmtree can remove them. Files inside
        # supervise/ are root-owned (death_tally, lock, status, written
        # by s6-supervise itself) — but the parent supervise/ directory
        # is hermes-owned (see ``_seed_supervise_skeleton``), and on
        # POSIX you only need write+execute on the parent to remove
        # contained files regardless of file ownership.
        shutil.rmtree(svc_dir, ignore_errors=True)

    def list_profile_gateways(self) -> list[str]:
        """Return the profile names of all currently-registered gateway services.

        Filters the scandir to entries that match the ``gateway-`` prefix.
        Other services (e.g. ``s6-linux-init-shutdownd``) are ignored.
        """
        if not self.scandir.exists():
            return []
        profiles: list[str] = []
        for entry in self.scandir.iterdir():
            if entry.name.startswith("."):
                continue
            if not entry.is_dir():
                continue
            if not entry.name.startswith(S6_SERVICE_PREFIX):
                continue
            profiles.append(entry.name[len(S6_SERVICE_PREFIX):])
        return profiles
