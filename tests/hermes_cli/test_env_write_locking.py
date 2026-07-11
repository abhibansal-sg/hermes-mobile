"""Concurrency/serialization regression tests for ``save_env_value`` /
``remove_env_value``.

Parent issue: STR-111 / STR-845. Reland: STR-883 (re-applied from STR-852
against a current base that serializes values via ``_quote_env_value``).

Without serialization, a dashboard "Save"/rotate can race a
"Disconnect"/Delete for the same slug and produce torn/partial ``.env`` lines
or a lost update that diverges the UI from server state. The fix holds
``_CONFIG_LOCK`` across the full read-modify-write of ``.env`` in both
writers, while preserving the existing ``_quote_env_value`` serialization of
the written value.

These tests prove, sleep-free:

* Concurrent writers of distinct keys never drop a key (lost-update race).
* Concurrent save/remove of the same key never leaves a torn/partial line and
  keeps ``load_env()`` consistent with the file.
* Concurrent saves of the same key always end on exactly one of the written
  values (deterministic last-writer, never a merged/garbled value).
* Forced save-then-remove and remove-then-save orderings yield the exact
  expected final state (deterministic last-writer semantics).
* ``save_env_value_secure`` inherits the guard by routing through
  ``save_env_value`` (no second lock layer).
"""

import os
import re
import threading

import pytest

from hermes_cli import config as config_mod
from hermes_cli.config import (
    load_env,
    remove_env_value,
    save_env_value,
    save_env_value_secure,
)


# Every line in a well-formed .env is either blank, a comment, or KEY=VALUE.
_WELL_FORMED = re.compile(r"^(?:[A-Za-z_][A-Za-z0-9_]*=.*|#.*)?$")


def _assert_env_well_formed(env_path):
    """No torn/partial lines: every physical line parses as KEY=VALUE (or
    blank/comment) and load_env() agrees with the file contents."""
    text = env_path.read_text(encoding="utf-8-sig")
    lines = text.split("\n")
    # Trailing newline produces a final empty element — allow it.
    if lines and lines[-1] == "":
        lines.pop()
    for ln in lines:
        assert _WELL_FORMED.match(ln), f"torn/partial .env line: {ln!r}"
    parsed = load_env()
    # load_env and a naive file parse must agree on every KEY= present.
    file_keys = {}
    for ln in lines:
        if ln and not ln.startswith("#") and "=" in ln:
            k, _, v = ln.partition("=")
            file_keys[k.strip()] = v.strip().strip("\"'")
    assert parsed == file_keys, f"load_env diverges from file: {parsed!r} vs {file_keys!r}"


@pytest.fixture(autouse=True)
def _isolated_hermes_home(tmp_path, monkeypatch):
    """Point HERMES_HOME at an isolated tmp dir and stop env leakage across
    tests. Snapshot/restore os.environ so keys written by save_env_value do
    not bleed into neighbouring tests."""
    keys_before = set(os.environ)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    # Managed mode would short-circuit the writers; ensure it's off.
    monkeypatch.delenv("HERMES_MANAGED", raising=False)
    yield
    for k in list(os.environ):
        if k not in keys_before:
            os.environ.pop(k, None)
    # Drop the process-level load_env() memo so it doesn't survive the run.
    config_mod.invalidate_env_cache()


class TestConcurrentEnvWrites:
    def test_concurrent_distinct_key_saves_all_survive(self, tmp_path):
        """Lost-update regression: without the lock, interleaved
        read-modify-write of ``.env`` drops keys because a writer overwrites
        the file with a stale snapshot that omits a concurrent sibling's
        newly-appended key. Under ``_CONFIG_LOCK`` every distinct key
        survives."""
        env_path = tmp_path / ".env"
        env_path.write_text("SEED=1\n", encoding="utf-8")

        n = 60

        def saver(i):
            save_env_value(f"UNIQ_{i:03d}", f"val_{i}")

        threads = [threading.Thread(target=saver, args=(i,)) for i in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        env = load_env()
        assert env["SEED"] == "1"
        for i in range(n):
            assert env[f"UNIQ_{i:03d}"] == f"val_{i}", (
                f"key UNIQ_{i:03d} lost — lost-update race not serialized"
            )
        _assert_env_well_formed(env_path)

    def test_concurrent_save_and_remove_same_key_no_torn_lines(self, tmp_path):
        """A save/rotate racing a remove/delete for the same slug (the
        STR-111 scenario) must never produce a torn/partial line or a file
        that load_env() cannot reproduce."""
        env_path = tmp_path / ".env"
        env_path.write_text("RACE=start\nOTHER=keep\n", encoding="utf-8")

        errors = []
        iters = 80

        def writer():
            try:
                for i in range(iters):
                    save_env_value("RACE", f"v{i:04d}")
            except BaseException as exc:  # noqa: BLE001 — surface any failure
                errors.append(exc)

        def remover():
            try:
                for i in range(iters):
                    remove_env_value("RACE")
            except BaseException as exc:  # noqa: BLE001
                errors.append(exc)

        threads = [threading.Thread(target=writer)] + [
            threading.Thread(target=remover) for _ in range(3)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert errors == [], f"writers raised: {errors!r}"
        _assert_env_well_formed(env_path)
        # OTHER must survive regardless of the RACE churn.
        assert load_env().get("OTHER") == "keep"

    def test_concurrent_same_key_saves_end_on_a_real_value(self, tmp_path):
        """Last-writer determinism for the same key: the final value must be
        exactly one of the written values — never a merge of two writes, a
        duplicated line, or a torn fragment."""
        env_path = tmp_path / ".env"
        env_path.write_text("RACE=initial\n", encoding="utf-8")

        values = [f"v{i:04d}" for i in range(120)]

        def saver(v):
            save_env_value("RACE", v)

        threads = [threading.Thread(target=saver, args=(v,)) for v in values]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        final = load_env().get("RACE")
        assert final in values, f"last-writer value {final!r} is not a written value"
        race_lines = [
            ln for ln in env_path.read_text(encoding="utf-8-sig").splitlines()
            if ln.startswith("RACE=")
        ]
        assert race_lines == [f"RACE={final}"], (
            f"expected a single RACE line, got {race_lines!r}"
        )


class TestDeterministicOrdering:
    """Force a known call order (no sleeps) and assert the exact final state.
    Order is forced by firing an Event from inside the first writer's
    ``atomic_replace`` — which only runs while ``_CONFIG_LOCK`` is held — so
    the second writer provably blocks on the lock until the first releases.
    """

    def _gated_replace_factory(self, gate, real_replace):
        def gating_replace(tmp, dest):
            if not gate.is_set():
                gate.set()
            return real_replace(tmp, dest)
        return gating_replace

    def test_save_then_remove_leaves_key_absent(self, tmp_path, monkeypatch):
        env_path = tmp_path / ".env"
        env_path.write_text("DEMO=initial\n", encoding="utf-8")

        save_entered = threading.Event()
        monkeypatch.setattr(
            config_mod,
            "atomic_replace",
            self._gated_replace_factory(save_entered, config_mod.atomic_replace),
        )

        results = {}

        def do_save():
            save_env_value("DEMO", "rotated")

        def do_remove():
            results["removed"] = remove_env_value("DEMO")

        t_save = threading.Thread(target=do_save)
        t_remove = threading.Thread(target=do_remove)
        t_save.start()
        save_entered.wait()  # save is now mid-critical-section, holding the lock
        t_remove.start()     # remove blocks on _CONFIG_LOCK until save exits
        t_save.join()
        t_remove.join()

        # Remove was the last writer and saw DEMO, so it removed it.
        assert results["removed"] is True
        assert "DEMO" not in load_env()
        assert "DEMO=" not in env_path.read_text(encoding="utf-8-sig")

    def test_remove_then_save_leaves_key_present(self, tmp_path, monkeypatch):
        env_path = tmp_path / ".env"
        env_path.write_text("DEMO=initial\n", encoding="utf-8")

        remove_entered = threading.Event()
        monkeypatch.setattr(
            config_mod,
            "atomic_replace",
            self._gated_replace_factory(remove_entered, config_mod.atomic_replace),
        )

        results = {}

        def do_remove():
            results["removed"] = remove_env_value("DEMO")

        def do_save():
            save_env_value("DEMO", "rotated")

        t_remove = threading.Thread(target=do_remove)
        t_save = threading.Thread(target=do_save)
        t_remove.start()
        remove_entered.wait()  # remove is mid-critical-section, holding the lock
        t_save.start()         # save blocks on the lock until remove exits
        t_remove.join()
        t_save.join()

        # Remove ran first and removed DEMO; save ran second and wrote it back.
        assert results["removed"] is True
        assert load_env().get("DEMO") == "rotated"
        _assert_env_well_formed(env_path)


class TestTransitiveGuard:
    def test_secure_save_routes_through_locked_save(self, tmp_path, monkeypatch):
        """``save_env_value_secure`` has no lock of its own — it must inherit
        the guard by calling ``save_env_value``. Verify the lock is acquired
        exactly once for a secure save (not zero, which would mean no guard)."""
        acquired = {"count": 0}
        real_lock = config_mod._CONFIG_LOCK

        class _CountingLock:
            def __enter__(self):
                acquired["count"] += 1
                return real_lock.__enter__()

            def __exit__(self, *exc):
                return real_lock.__exit__(*exc)

        monkeypatch.setattr(config_mod, "_CONFIG_LOCK", _CountingLock())

        result = save_env_value_secure("INHERITED_KEY", "secret-value")

        assert result == {
            "success": True,
            "stored_as": "INHERITED_KEY",
            "validated": False,
        }
        assert acquired["count"] == 1, (
            f"save_env_value_secure did not acquire _CONFIG_LOCK exactly once "
            f"(acquired={acquired['count']})"
        )
        assert load_env().get("INHERITED_KEY") == "secret-value"
