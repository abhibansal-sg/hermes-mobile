#!/usr/bin/env python3
"""Run only pytest files affected by a Git merge-base diff.

This helper keeps ``scripts/verify.sh --changed`` small and testable. It
computes the changed paths itself, maps Python sources to likely tests, and
then delegates to the canonical per-file runner. Broad changes deliberately
fall back to that runner with no path arguments, preserving the full gate.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Sequence


BROAD_PATHS = frozenset(
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
MAX_REPORTED_PATHS = 50
LOG_PREFIX = "[verify --changed]"


class GitDiffError(RuntimeError):
    """Raised when the requested merge-base diff cannot be computed."""


@dataclass(frozen=True)
class TestSelection:
    """The pytest scope selected for a set of changed repository paths."""

    tests: tuple[str, ...]
    unmapped_sources: tuple[str, ...]
    removed_tests: tuple[str, ...]
    broad_paths: tuple[str, ...]

    @property
    def requires_full_suite(self) -> bool:
        return bool(self.broad_paths)


def changed_paths(repo_root: Path, base_ref: str) -> tuple[str, ...]:
    """Return paths changed by ``base_ref...HEAD`` using its merge base."""

    merge_base = subprocess.run(
        ["git", "merge-base", "--", base_ref, "HEAD"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )
    if merge_base.returncode != 0 or not merge_base.stdout.strip():
        detail = merge_base.stderr.strip() or "no merge base found"
        raise GitDiffError(f"cannot resolve merge base for {base_ref!r}: {detail}")

    diff = subprocess.run(
        [
            "git",
            "diff",
            "--name-only",
            "-z",
            merge_base.stdout.strip(),
            "HEAD",
            "--",
        ],
        cwd=repo_root,
        capture_output=True,
        check=False,
    )
    if diff.returncode != 0:
        detail = os.fsdecode(diff.stderr).strip() or "git diff failed"
        raise GitDiffError(f"cannot diff {base_ref!r}...HEAD: {detail}")

    return tuple(
        sorted({os.fsdecode(raw_path) for raw_path in diff.stdout.split(b"\0") if raw_path})
    )


def _test_files(repo_root: Path) -> tuple[str, ...]:
    tests_root = repo_root / "tests"
    if not tests_root.is_dir():
        return ()
    return tuple(
        sorted(
            path.relative_to(repo_root).as_posix()
            for path in tests_root.rglob("test_*.py")
            if path.is_file()
        )
    )


def _source_module(source_path: str) -> tuple[str, str, str] | None:
    parts = list(PurePosixPath(source_path).with_suffix("").parts)
    if parts and parts[-1] == "__init__":
        parts.pop()
    if not parts:
        return None
    module = ".".join(parts)
    package = ".".join(parts[:-1])
    return module, package, parts[-1]


def _imports_module(test_source: str, module: str, package: str, leaf: str) -> bool:
    module_token = rf"(?<![\w.]){re.escape(module)}(?![\w.])"
    if re.search(rf"(?m)^\s*import\s+[^#\n]*{module_token}", test_source):
        return True
    if re.search(rf"(?m)^\s*from\s+{re.escape(module)}\s+import\b", test_source):
        return True
    if not package:
        return False

    parent_import = re.compile(
        rf"(?ms)^\s*from\s+{re.escape(package)}\s+import\s+"
        r"(?P<names>\([^)]*\)|[^#\n]*)"
    )
    leaf_token = re.compile(rf"(?<![\w.]){re.escape(leaf)}(?![\w.])")
    return any(leaf_token.search(match.group("names")) for match in parent_import.finditer(test_source))


def select_tests(repo_root: Path, paths: Sequence[str]) -> TestSelection:
    """Map changed paths to runnable test files, or request the full suite."""

    normalized_paths = tuple(sorted(set(paths)))
    broad_paths = tuple(path for path in normalized_paths if path in BROAD_PATHS)
    if broad_paths:
        return TestSelection((), (), (), broad_paths)

    available_tests = _test_files(repo_root)
    contents: dict[str, str] = {}
    affected: set[str] = set()
    removed_tests: list[str] = []
    unmapped_sources: list[str] = []

    for changed_path in normalized_paths:
        path = PurePosixPath(changed_path)
        if changed_path.startswith("tests/"):
            if path.suffix == ".py" and path.name.startswith("test_"):
                if (repo_root / changed_path).is_file():
                    affected.add(changed_path)
                else:
                    removed_tests.append(changed_path)
                continue
            if path.name == "conftest.py":
                subtree_prefix = f"{path.parent.as_posix()}/"
                subtree_tests = {
                    test_path
                    for test_path in available_tests
                    if test_path.startswith(subtree_prefix)
                }
                if subtree_tests:
                    affected.update(subtree_tests)
                else:
                    unmapped_sources.append(changed_path)
                continue

        if path.suffix != ".py":
            continue

        source_matches = {
            test_path
            for test_path in available_tests
            if path.stem in PurePosixPath(test_path).name
        }
        module_parts = _source_module(changed_path)
        if module_parts is not None:
            module, package, leaf = module_parts
            for test_path in available_tests:
                if test_path in source_matches:
                    continue
                test_source = contents.get(test_path)
                if test_source is None:
                    test_source = (repo_root / test_path).read_text(
                        encoding="utf-8", errors="replace"
                    )
                    contents[test_path] = test_source
                if _imports_module(test_source, module, package, leaf):
                    source_matches.add(test_path)

        if source_matches:
            affected.update(source_matches)
        else:
            unmapped_sources.append(changed_path)

    return TestSelection(
        tests=tuple(sorted(affected)),
        unmapped_sources=tuple(sorted(unmapped_sources)),
        removed_tests=tuple(sorted(removed_tests)),
        broad_paths=(),
    )


def _log(message: str) -> None:
    print(f"{LOG_PREFIX} {message}", flush=True)


def _log_paths(paths: Sequence[str]) -> None:
    for path in paths[:MAX_REPORTED_PATHS]:
        _log(f"  {path}")
    remaining = len(paths) - MAX_REPORTED_PATHS
    if remaining > 0:
        _log(f"  ... {remaining} more path(s) omitted")


def _run_tests(repo_root: Path, tests: Sequence[str]) -> int:
    runner = repo_root / "scripts" / "run_tests.sh"
    if not runner.is_file():
        _log(f"ERROR: canonical test runner is missing: {runner}")
        return 2
    result = subprocess.run([str(runner), *tests], cwd=repo_root, check=False)
    if result.returncode < 0:
        return 128 + abs(result.returncode)
    return result.returncode


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run pytest files affected by a merge-base diff."
    )
    parser.add_argument("base_ref", help="Git ref compared to HEAD with merge-base semantics")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve()

    try:
        paths = changed_paths(repo_root, args.base_ref)
    except GitDiffError as exc:
        _log(f"ERROR: {exc}")
        return 2

    selection = select_tests(repo_root, paths)
    if selection.requires_full_suite:
        _log(
            f"broad/core change detected against {args.base_ref!r}; "
            "running the full pytest gate"
        )
        _log_paths(selection.broad_paths)
        result = _run_tests(repo_root, ())
        _log(f"--changed: full pytest fallback ran (exit {result})")
        return result

    if selection.unmapped_sources:
        _log(
            "WARNING: changed source file(s) mapped to no test "
            f"({len(selection.unmapped_sources)}):"
        )
        _log_paths(selection.unmapped_sources)
    if selection.removed_tests:
        _log(
            "WARNING: changed test file(s) no longer exist and cannot be run "
            f"({len(selection.removed_tests)}):"
        )
        _log_paths(selection.removed_tests)

    if not selection.tests:
        _log(
            f"--changed: 0 affected test files for {args.base_ref!r}; "
            "pytest gate PASS (runner not invoked)"
        )
        return 0

    _log(
        f"affected test files for {args.base_ref!r} "
        f"({len(selection.tests)}; per-file isolation):"
    )
    _log_paths(selection.tests)
    result = _run_tests(repo_root, selection.tests)
    _log(
        f"--changed: {len(selection.tests)} test file(s) affected by "
        f"{args.base_ref!r}; ran per-file (exit {result})"
    )
    return result


if __name__ == "__main__":
    sys.exit(main())
