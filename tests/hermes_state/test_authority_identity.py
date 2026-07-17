import sqlite3

import pytest

from hermes_state import SessionDB, StateAuthorityIdentityError


PROFILE_A = "pf_AAAAAAAAAAAAAAAAAAAAAA"
PROFILE_B = "pf_BBBBBBBBBBBBBBBBBBBBBB"


def test_authority_identity_is_atomic_and_stable(tmp_path):
    path = tmp_path / "state.db"
    db = SessionDB(path)
    first = db.get_or_create_authority_identity(expected_profile_id=PROFILE_A)
    second = db.get_or_create_authority_identity(expected_profile_id=PROFILE_A)
    assert first == second
    assert first.profile_id == PROFILE_A
    assert first.authority_epoch.startswith("ae_")
    db.close()

    reopened = SessionDB(path)
    assert reopened.read_authority_identity() == first
    reopened.close()


def test_read_only_connection_never_creates_identity(tmp_path):
    path = tmp_path / "state.db"
    writable = SessionDB(path)
    writable.close()
    read_only = SessionDB(path, read_only=True)
    assert read_only.read_authority_identity() is None
    with pytest.raises(StateAuthorityIdentityError, match="read-only"):
        read_only.get_or_create_authority_identity(expected_profile_id=PROFILE_A)
    read_only.close()


def test_copied_database_profile_mismatch_fails_closed(tmp_path):
    db = SessionDB(tmp_path / "state.db")
    db.get_or_create_authority_identity(expected_profile_id=PROFILE_A)
    with pytest.raises(StateAuthorityIdentityError, match="another profile"):
        db.get_or_create_authority_identity(expected_profile_id=PROFILE_B)
    db.close()


def test_partial_identity_fails_closed(tmp_path):
    path = tmp_path / "state.db"
    db = SessionDB(path)
    db.set_meta("authority_epoch", "ae_AAAAAAAAAAAAAAAAAAAAAA")
    with pytest.raises(StateAuthorityIdentityError, match="partial"):
        db.read_authority_identity()
    db.close()


def test_explicit_epoch_rotation_preserves_profile(tmp_path):
    db = SessionDB(tmp_path / "state.db")
    first = db.get_or_create_authority_identity(expected_profile_id=PROFILE_A)
    rotated = db.rotate_authority_epoch(expected_profile_id=PROFILE_A)
    assert rotated.profile_id == first.profile_id
    assert rotated.authority_epoch != first.authority_epoch
    assert db.read_authority_identity() == rotated
    db.close()


def test_active_message_heads_are_bounded_and_content_free(tmp_path):
    db = SessionDB(tmp_path / "state.db")
    db.create_session("older", source="cli")
    db.append_message("older", role="user", content="must not leak", timestamp=10.0)
    db.create_session("newer", source="cli")
    db.append_message("newer", role="user", content="also secret", timestamp=20.0)

    heads = db.list_active_message_heads(limit=1)
    assert heads == [{
        "session_id": "newer",
        "max_message_id": heads[0]["max_message_id"],
        "message_count": 1,
        "last_message_at": 20.0,
    }]
    assert "content" not in heads[0]

    with pytest.raises(ValueError, match="between 1 and 100000"):
        db.list_active_message_heads(limit=0)
    with pytest.raises(ValueError, match="between 1 and 100000"):
        db.list_active_message_heads(limit=100_001)
    db.close()
