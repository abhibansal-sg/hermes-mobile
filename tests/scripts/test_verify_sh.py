"""STR-1340: minimal smoke/self-test for scripts/verify.sh.

Mirrors the existing tests/hermes_cli/test_setup_hermes_script.py pattern —
a fast, pytest-visible assertion that the deterministic V4 verifier gate
exists, is syntactically valid, is executable, and documents its
intentionally-skipped lanes. Does NOT invoke the gate itself (that requires
a real .venv/npm workspace/iOS toolchain and can take tens of minutes) —
scripts/verify.sh --self-test covers that heavier liveness check instead.
"""

import os
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
VERIFY_SCRIPT = REPO_ROOT / "scripts" / "verify.sh"


def test_verify_sh_exists():
    assert VERIFY_SCRIPT.is_file(), f"{VERIFY_SCRIPT} is missing"


def test_verify_sh_is_executable():
    assert os.access(VERIFY_SCRIPT, os.X_OK), f"{VERIFY_SCRIPT} is not executable (chmod +x)"


def test_verify_sh_is_valid_shell():
    result = subprocess.run(["bash", "-n", str(VERIFY_SCRIPT)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_verify_sh_self_test_passes():
    """--self-test is the script's own lightweight liveness check (bash -n +
    executable-bit), runnable in CI without a full .venv/npm/iOS toolchain."""
    result = subprocess.run(
        ["bash", str(VERIFY_SCRIPT), "--self-test"],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "PASS" in result.stdout


def test_verify_sh_documents_skipped_lanes():
    """Acceptance criterion: any intentionally skipped heavyweight lane must
    print a reason. Assert the known-skipped lanes are named with a reason,
    not silently dropped."""
    content = VERIFY_SCRIPT.read_text(encoding="utf-8")
    for lane in ("docker", "docs-site", "supply-chain-audit", "osv-scanner"):
        assert f'skip {lane} "' in content, f"lane '{lane}' has no documented skip reason"


def test_verify_sh_gates_run_via_ios_build_wrapper_not_raw_xcodebuild():
    """loop-common iOS build law: verify.sh must route through the
    single-flight scripts/ios-build.sh wrapper, never call xcodebuild
    directly (the wrapper serializes machine-wide to avoid the
    SWBBuildService wedge)."""
    content = VERIFY_SCRIPT.read_text(encoding="utf-8")
    assert "ios-build.sh build" in content
    assert "xcodebuild " not in content.replace("./scripts/ios-build.sh", "")
