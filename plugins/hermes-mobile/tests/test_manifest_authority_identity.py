from __future__ import annotations

# Plugin-level installation/manifest identity contract tests.

import importlib.util
import sys
from pathlib import Path

from hermes_cli.profiles import ensure_profile_id


def _load_module():
    path = Path(__file__).parents[1] / "authority_identity.py"
    name = f"authority_identity_test_{id(path)}"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    assert spec.loader
    spec.loader.exec_module(module)
    return module


def test_installation_and_profile_authority_survive_restart(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    identity = _load_module()
    first = identity.ensure_profile_authority("default", tmp_path)
    second = identity.ensure_profile_authority("default", tmp_path)
    assert first == second
    assert first.gateway_id.startswith("gw_")
    assert first.profiles[0].profile_id.startswith("pf_")
    assert first.profiles[0].authority_epoch.startswith("ae_")
    assert (tmp_path / "mobile" / "authority-identity-v1.json").exists()


def test_replacing_one_database_rotates_only_its_epoch(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    identity = _load_module()
    first = identity.ensure_profile_authority("default", tmp_path)
    for suffix in ("", "-wal", "-shm"):
        Path(str(tmp_path / "state.db") + suffix).unlink(missing_ok=True)
    second = identity.ensure_profile_authority("default", tmp_path)
    assert second.gateway_id == first.gateway_id
    assert second.profiles[0].profile_id == first.profiles[0].profile_id
    assert second.profiles[0].authority_epoch != first.profiles[0].authority_epoch


def test_read_only_authority_map_is_sorted_and_detects_duplicates(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    identity = _load_module()
    identity.ensure_profile_authority("default", tmp_path)
    other = tmp_path / "profiles" / "other"
    other.mkdir(parents=True)
    identity.ensure_profile_authority("other", other)
    result = identity.read_profile_authorities(
        (("other", other), ("default", tmp_path))
    )
    assert [item.profile_id for item in result.profiles] == sorted(
        item.profile_id for item in result.profiles
    )

    # A copied profile.yaml is a conflict, not a reason to guess/rekey.
    copied = tmp_path / "profiles" / "copied"
    copied.mkdir(parents=True)
    (copied / "profile.yaml").write_text(
        (other / "profile.yaml").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    from hermes_state import SessionDB

    db = SessionDB(copied / "state.db")
    db.get_or_create_authority_identity(
        expected_profile_id=ensure_profile_id(copied)
    )
    db.close()
    try:
        identity.read_profile_authorities((("other", other), ("copied", copied)))
    except identity.AuthorityIdentityError as exc:
        assert "duplicate profile_id" in str(exc)
    else:  # pragma: no cover - assertion clarity
        raise AssertionError("duplicate profile identity was accepted")
