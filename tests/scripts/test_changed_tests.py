"""Behavior tests for the affected-only pytest verifier gate."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from scripts import changed_tests


REPO_ROOT = Path(__file__).resolve().parents[2]
VERIFY_SCRIPT = REPO_ROOT / "scripts" / "verify.sh"
SELECTOR_SCRIPT = REPO_ROOT / "scripts" / "changed_tests.py"
MINIMAL_PATH = "/usr/bin:/bin"
EXPECTED_BROAD_PATHS = frozenset(
    {
        "tests/conftest.py",
        "pyproject.toml",
        "run_agent.py",
        "hermes_state.py",
        "model_tools.py",
        "scripts/run_tests.sh",
        "scripts/verify.sh",
    }
)


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def _commit(repo: Path, message: str) -> str:
    _git(repo, "add", ".")
    _git(repo, "commit", "-q", "-m", message)
    return _git(repo, "rev-parse", "HEAD")


def _make_repo(tmp_path: Path) -> tuple[Path, str, Path]:
    repo = tmp_path / "repo"
    scripts = repo / "scripts"
    scripts.mkdir(parents=True)
    shutil.copy2(VERIFY_SCRIPT, scripts / "verify.sh")
    shutil.copy2(SELECTOR_SCRIPT, scripts / "changed_tests.py")
    _write(
        scripts / "run_tests.sh",
        """#!/usr/bin/env bash
set -euo pipefail
: > "$RUNNER_LOG"
printf '%s\n' "$#" > "$RUNNER_LOG.count"
for arg in "$@"; do
  printf '%s\\0' "$arg" >> "$RUNNER_LOG"
done
""",
    )
    (scripts / "run_tests.sh").chmod(0o755)
    _write(repo / ".gitignore", ".venv/\n")

    _write(repo / "agent" / "payment_service.py", "VALUE = 1\n")
    _write(
        repo / "tests" / "agent" / "test_checkout.py",
        "from agent import payment_service\n\ndef test_checkout():\n    assert payment_service.VALUE\n",
    )
    _write(
        repo / "tests" / "agent" / "test_unrelated.py",
        "def test_unrelated():\n    assert True\n",
    )

    _git(repo, "init", "-q")
    _git(repo, "config", "user.email", "verify-tests@example.invalid")
    _git(repo, "config", "user.name", "Verify Tests")
    base_ref = _commit(repo, "base")

    # verify.sh intentionally requires a local venv before entering the pytest
    # gate. The selector itself is stdlib-only, so the current test venv is a
    # faithful and fast stand-in.
    (repo / ".venv" / "bin").mkdir(parents=True)
    (repo / ".venv" / "bin" / "python").symlink_to(sys.executable)
    return repo, base_ref, tmp_path / "runner.log"


def _change(repo: Path, path: str, content: str | None = None) -> None:
    target = repo / path
    if content is None and target.exists():
        content = target.read_text(encoding="utf-8") + "\n# changed\n"
    _write(target, content or "# changed\n")
    _commit(repo, f"change {path}")


def _run_verify(repo: Path, runner_log: Path, *args: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "PATH": MINIMAL_PATH,
            "RUNNER_LOG": str(runner_log),
        }
    )
    return subprocess.run(
        ["bash", "scripts/verify.sh", *args],
        cwd=repo,
        env=env,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )


def _runner_args(runner_log: Path) -> tuple[str, ...]:
    raw = runner_log.read_bytes()
    return tuple(part.decode() for part in raw.split(b"\0") if part)


def test_select_tests_unions_stem_import_and_direct_matches(tmp_path):
    _write(tmp_path / "tests" / "test_runtime_widget_behavior.py", "def test_widget(): pass\n")
    _write(
        tmp_path / "tests" / "test_checkout.py",
        "from agent import (\n    payment_service as service,\n)\n",
    )
    _write(tmp_path / "tests" / "test_direct.py", "def test_direct(): pass\n")

    selection = changed_tests.select_tests(
        tmp_path,
        [
            "agent/widget.py",
            "agent/payment_service.py",
            "tests/test_direct.py",
            "tests/test_direct.py",
        ],
    )

    assert selection.tests == (
        "tests/test_checkout.py",
        "tests/test_direct.py",
        "tests/test_runtime_widget_behavior.py",
    )
    assert selection.unmapped_sources == ()
    assert not selection.requires_full_suite


def test_select_tests_maps_nested_conftest_and_reports_test_helpers(tmp_path):
    _write(
        tmp_path / "tests" / "gateway" / "conftest.py",
        "@pytest.fixture\ndef event(): pass\n",
    )
    _write(tmp_path / "tests" / "gateway" / "test_direct.py", "def test_direct(): pass\n")
    _write(
        tmp_path / "tests" / "gateway" / "nested" / "test_nested.py",
        "def test_nested(): pass\n",
    )
    _write(
        tmp_path / "tests" / "gateway" / "restart_test_helpers.py",
        "def make_restart_runner(): pass\n",
    )
    _write(
        tmp_path / "tests" / "other" / "test_restart_consumer.py",
        "from tests.gateway.restart_test_helpers import make_restart_runner\n",
    )
    _write(
        tmp_path / "tests" / "gateway_extra" / "test_outside_subtree.py",
        "def test_outside(): pass\n",
    )
    _write(tmp_path / "tests" / "run_interrupt_test.py", "def main(): pass\n")

    selection = changed_tests.select_tests(
        tmp_path,
        [
            "tests/gateway/conftest.py",
            "tests/gateway/restart_test_helpers.py",
            "tests/run_interrupt_test.py",
        ],
    )

    assert selection.tests == (
        "tests/gateway/nested/test_nested.py",
        "tests/gateway/test_direct.py",
        "tests/other/test_restart_consumer.py",
    )
    assert selection.unmapped_sources == ("tests/run_interrupt_test.py",)
    assert not selection.requires_full_suite


def test_broad_path_policy_matches_frozen_contract():
    assert changed_tests.BROAD_PATHS == EXPECTED_BROAD_PATHS


def test_changed_paths_uses_merge_base_for_divergent_history(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q")
    _git(repo, "config", "user.email", "verify-tests@example.invalid")
    _git(repo, "config", "user.name", "Verify Tests")
    _write(repo / "shared.txt", "shared\n")
    root_commit = _commit(repo, "shared root")

    _git(repo, "checkout", "-q", "-b", "base-side")
    _write(repo / "base-only.txt", "base only\n")
    _commit(repo, "base-only change")

    _git(repo, "checkout", "-q", "--detach", root_commit)
    _write(repo / "agent" / "head_only.py", "HEAD_ONLY = True\n")
    _commit(repo, "head-only change")

    assert changed_tests.changed_paths(repo, "base-side") == ("agent/head_only.py",)


@pytest.mark.parametrize("broad_path", sorted(changed_tests.BROAD_PATHS))
def test_every_broad_path_requests_full_suite(tmp_path, broad_path):
    selection = changed_tests.select_tests(tmp_path, ["docs/readme.md", broad_path])

    assert selection.requires_full_suite
    assert selection.broad_paths == (broad_path,)
    assert selection.tests == ()


def test_changed_mode_runs_only_import_mapped_test(tmp_path):
    repo, base_ref, runner_log = _make_repo(tmp_path)
    _change(repo, "agent/payment_service.py", "VALUE = 2\n")

    result = _run_verify(
        repo,
        runner_log,
        "--changed",
        base_ref,
        "--skip-ts",
        "--skip-ios",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert _runner_args(runner_log) == ("tests/agent/test_checkout.py",)
    assert "1 test file(s) affected" in result.stdout
    assert "tests/agent/test_checkout.py" in result.stdout


def test_changed_mode_deduplicates_direct_and_source_matches(tmp_path):
    repo, base_ref, runner_log = _make_repo(tmp_path)
    _change(repo, "agent/payment_service.py", "VALUE = 2\n")
    _change(
        repo,
        "tests/agent/test_checkout.py",
        "from agent import payment_service\n\ndef test_checkout():\n    assert payment_service.VALUE == 2\n",
    )

    result = _run_verify(
        repo,
        runner_log,
        "--changed",
        base_ref,
        "--skip-ts",
        "--skip-ios",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert _runner_args(runner_log) == ("tests/agent/test_checkout.py",)
    assert runner_log.with_suffix(".log.count").read_text(encoding="utf-8").strip() == "1"


@pytest.mark.parametrize("broad_path", sorted(changed_tests.BROAD_PATHS))
def test_changed_mode_broad_diff_invokes_full_runner(tmp_path, broad_path):
    repo, base_ref, runner_log = _make_repo(tmp_path)
    _change(repo, broad_path)

    result = _run_verify(
        repo,
        runner_log,
        "--changed",
        base_ref,
        "--skip-ts",
        "--skip-ios",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert _runner_args(runner_log) == ()
    assert runner_log.with_suffix(".log.count").read_text(encoding="utf-8").strip() == "0"
    assert "broad/core change detected" in result.stdout
    assert broad_path in result.stdout
    assert "full pytest fallback ran" in result.stdout


def test_changed_mode_warns_for_unmapped_source_without_running_pytest(tmp_path):
    repo, base_ref, runner_log = _make_repo(tmp_path)
    _change(repo, "agent/orphaned_source.py", "ORPHANED = True\n")

    result = _run_verify(
        repo,
        runner_log,
        "--changed",
        base_ref,
        "--skip-ts",
        "--skip-ios",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert not runner_log.exists()
    assert "WARNING: changed source file(s) mapped to no test (1)" in result.stdout
    assert "agent/orphaned_source.py" in result.stdout
    assert "0 affected test files" in result.stdout
    assert "VERDICT: PASS" in result.stdout


def test_changed_mode_non_python_diff_is_explicit_zero_affected_pass(tmp_path):
    repo, base_ref, runner_log = _make_repo(tmp_path)
    _change(repo, "docs/readme.md", "documentation only\n")

    result = _run_verify(
        repo,
        runner_log,
        "--changed",
        base_ref,
        "--skip-ts",
        "--skip-ios",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert not runner_log.exists()
    assert "0 affected test files" in result.stdout
    assert "runner not invoked" in result.stdout


@pytest.mark.parametrize(
    "args",
    [
        ("--changed", "{base}", "--skip-pytest", "--skip-ts", "--skip-ios"),
        ("--skip-pytest", "--skip-ts", "--skip-ios", "--changed", "{base}"),
    ],
)
def test_skip_pytest_composes_with_changed_in_any_order(tmp_path, args):
    repo, base_ref, runner_log = _make_repo(tmp_path)
    _change(repo, "agent/payment_service.py", "VALUE = 2\n")
    resolved_args = tuple(base_ref if arg == "{base}" else arg for arg in args)

    result = _run_verify(repo, runner_log, *resolved_args)

    assert result.returncode == 0, result.stdout + result.stderr
    assert not runner_log.exists()
    assert "pytest: SKIPPED — --skip-pytest" in result.stdout


def test_argumentless_verify_preserves_full_pytest_runner(tmp_path):
    repo, _, runner_log = _make_repo(tmp_path)

    result = _run_verify(repo, runner_log, "--skip-ts", "--skip-ios")

    assert result.returncode == 0, result.stdout + result.stderr
    assert _runner_args(runner_log) == ()
    assert runner_log.with_suffix(".log.count").read_text(encoding="utf-8").strip() == "0"
    assert "pytest: PASS" in result.stdout


def test_changed_requires_base_ref_before_running_any_gate():
    result = subprocess.run(
        ["bash", str(VERIFY_SCRIPT), "--changed"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )

    assert result.returncode == 2
    assert "--changed requires <base-ref>" in result.stderr
    assert "usage: scripts/verify.sh --changed <base-ref> [flags]" in result.stderr
    assert "GATE:" not in result.stdout
