"""W3A-S — per-device pairing tokens: the device-token registry unit tests
(hashing, prefix, normalization, 0600 writes, corrupt-file handling, revoke
deny-set semantics).

NOTE (ABH-88 de-patch W1): the REST endpoint tests (issue/list/revoke under
what is now ``/api/plugins/hermes-mobile/devices*``) moved to
``tests/plugins/hermes_mobile/test_devices_endpoints.py``.

NOTE (ABH-88 de-patch W2b): the registry module moved too —
``hermes_cli/device_tokens.py`` is now ``plugins/hermes-mobile/device_tokens.py``
(same API) — so these unit tests load it through the plugin namespace.

All tests use a throwaway HERMES_HOME so the registry never touches ~/.hermes.
"""

from __future__ import annotations

import json
import os
import stat
from types import SimpleNamespace

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module

device_tokens = load_plugin_module("device_tokens")


@pytest.fixture
def home(monkeypatch, tmp_path):
    """Throwaway HERMES_HOME so device_tokens.json never touches ~/.hermes."""
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    device_tokens._reset_for_tests()
    yield tmp_path
    device_tokens._reset_for_tests()


# ===========================================================================
# 1. Registry unit: hashing, prefix, normalization, 0600, corrupt-file
# ===========================================================================


def test_issue_returns_token_once_and_stores_only_hash(home):
    out = device_tokens.issue(device_name="My Phone")
    assert set(out) == {"device_id", "token", "device_name", "created_at"}
    assert out["device_id"].startswith("dev_")
    token = out["token"]
    # On-disk: only the hash + prefix, never the token.
    raw = (home / "device_tokens.json").read_text()
    assert token not in raw
    import hashlib

    assert hashlib.sha256(token.encode()).hexdigest() in raw
    assert token[:8] in raw  # the prefix is stored


def test_issue_raises_when_registry_limit_reached(home, monkeypatch):
    monkeypatch.setattr(device_tokens, "_MAX_DEVICES", 1)
    device_tokens.issue(device_name="Phone A")

    with pytest.raises(device_tokens.DeviceLimitError):
        device_tokens.issue(device_name="Phone B")


def test_registry_file_is_mode_0600(home):
    device_tokens.issue(device_name="x")
    mode = stat.S_IMODE(os.stat(home / "device_tokens.json").st_mode)
    assert mode == 0o600


def test_registry_uses_atomic_0600_writer(home, monkeypatch):
    calls = []
    real_writer = device_tokens.atomic_json_write

    def spy(path, data, **kwargs):
        calls.append((path, kwargs))
        return real_writer(path, data, **kwargs)

    monkeypatch.setattr(device_tokens, "atomic_json_write", spy)

    device_tokens.issue(device_name="x")

    assert calls
    assert calls[-1][0] == home / "device_tokens.json"
    assert calls[-1][1]["mode"] == 0o600


def test_match_is_correct_and_bumps_last_seen(home):
    out = device_tokens.issue(device_name="x")
    before = json.loads((home / "device_tokens.json").read_text())
    dev = device_tokens.match(out["token"])
    assert dev is not None
    assert dev["device_id"] == out["device_id"]
    assert dev["device_name"] == "x"
    assert dev["token_prefix"] == out["token"][:8]
    after = json.loads((home / "device_tokens.json").read_text())
    assert after[out["device_id"]]["last_seen"] >= before[out["device_id"]]["last_seen"]


def test_match_rejects_wrong_token_and_garbage(home):
    device_tokens.issue(device_name="x")
    assert device_tokens.match("not-a-real-token") is None
    assert device_tokens.match("") is None
    assert device_tokens.match(None) is None
    assert device_tokens.match("z" * 9999) is None  # oversized → no disk touch


def test_normalize_device_name(home):
    assert device_tokens._normalize_device_name("  Bob's\x00 iPhone  ") == "Bob's iPhone"
    assert device_tokens._normalize_device_name("") == "iPhone"
    assert device_tokens._normalize_device_name(None) == "iPhone"
    assert device_tokens._normalize_device_name(123) == "iPhone"
    assert len(device_tokens._normalize_device_name("a" * 200)) == 64


def test_corrupt_registry_yields_empty_not_crash(home):
    (home / "device_tokens.json").write_text("{ not json")
    assert device_tokens.list_devices() == []
    assert device_tokens.match("anything") is None


def test_revoke_unknown_returns_false(home):
    assert device_tokens.revoke("dev_nope") is False


def test_revoke_removes_entry_and_token_stops_matching(home):
    out = device_tokens.issue(device_name="x")
    assert device_tokens.is_device_active(out["device_id"]) is True
    assert device_tokens.match(out["token"]) is not None
    assert device_tokens.revoke(out["device_id"]) is True
    assert device_tokens.match(out["token"]) is None
    assert device_tokens.is_device_active(out["device_id"]) is False
    assert device_tokens.list_devices() == []


# ---------------------------------------------------------------------------
# R1-fix finding 3: a revoke whose disk write FAILS must STILL kill the token
# for the process lifetime (in-process deny-set), and must RAISE so the endpoint
# can report the persisted file is stale rather than claim a clean revoke.
# ---------------------------------------------------------------------------


def test_revoke_holds_via_deny_set_when_disk_write_fails(home, monkeypatch):
    """A failed ``_save`` during revoke: the token stops matching anyway (the
    deny-set is consulted by ``match`` even though the stale file still lists it),
    and revoke RAISES so the caller knows persistence failed."""
    out = device_tokens.issue(device_name="x")
    token = out["token"]
    assert device_tokens.match(token) is not None

    # Simulate a read-only / full registry: the write fails after we've recorded
    # the deny-hash. The token hash is STILL physically on disk (the file was not
    # rewritten), so a deny-set miss would let it re-authenticate.
    monkeypatch.setattr(device_tokens, "_save", lambda entries: False)

    with pytest.raises(device_tokens.DeviceRegistryError):
        device_tokens.revoke(out["device_id"])

    # The on-disk file is unchanged (write failed) — proves we are NOT relying on
    # the file for the revocation to hold.
    on_disk = json.loads((home / "device_tokens.json").read_text())
    assert out["device_id"] in on_disk
    assert on_disk[out["device_id"]]["token_hash"] == \
        device_tokens._hash_token(token)

    # ...yet the token no longer authenticates: the deny-set wins.
    assert device_tokens.match(token) is None
    assert device_tokens.is_device_active(out["device_id"]) is False


def test_deny_set_survives_a_stale_registry_reload(home, monkeypatch):
    """Even if the on-disk registry is reloaded fresh each ``match`` (it is), a
    deny-listed hash never re-matches — the failure mode the bug allowed."""
    out = device_tokens.issue(device_name="x")
    token = out["token"]
    monkeypatch.setattr(device_tokens, "_save", lambda entries: False)
    with pytest.raises(device_tokens.DeviceRegistryError):
        device_tokens.revoke(out["device_id"])
    # Two reloads, both denied (no flakiness from any caching).
    assert device_tokens.match(token) is None
    assert device_tokens.match(token) is None


def test_deny_set_is_cleared_by_reset_for_tests(home):
    """``_reset_for_tests`` clears the deny-set so test isolation holds (a fresh
    HERMES_HOME + reset must not carry a prior test's revoked hashes)."""
    out = device_tokens.issue(device_name="x")
    device_tokens.revoke(out["device_id"])  # disk write succeeds here
    # Re-issue is a brand-new token/hash, but assert the set itself is emptied so
    # a hypothetical hash collision across tests can't leak.
    device_tokens._reset_for_tests()
    assert device_tokens._revoked_hashes == set()


# ---------------------------------------------------------------------------
# ABH-252: runtime-session → device correlation must not leak forever.
# ---------------------------------------------------------------------------


def test_session_device_index_is_bounded_across_many_closed_sessions(home, monkeypatch):
    """Core session close/delete has no plugin lifecycle callback, so 500 closed
    runtime session ids on one still-live phone socket must not leave 500 stale
    correlation rows behind."""
    monkeypatch.setattr(device_tokens, "_MAX_SESSION_DEVICE_INDEX", 64)
    issued = device_tokens.issue(device_name="Abhi's iPhone")
    ws = object()
    transport = SimpleNamespace(_ws=ws)
    device_tokens.register_ws_socket(issued["device_id"], ws)

    for idx in range(500):
        result = device_tokens.record_session_transport(f"closed-session-{idx}", transport)
        assert result == {"device_id": issued["device_id"]}
        # Simulated close: the core runtime session is gone, but the plugin gets
        # no per-session close signal. The bound must hold without an explicit
        # ``clear_session_transport`` call.

    assert len(device_tokens._session_device_sockets) <= 64
    assert len(device_tokens._session_device_sockets) != 500
    assert device_tokens.device_identity_for_session("closed-session-0") is None
    assert device_tokens.device_identity_for_session("closed-session-499") == {
        "device_id": issued["device_id"]
    }


def test_session_device_index_prunes_expired_entries(home, monkeypatch):
    """Idle runtime-session correlations self-clean before reuse/lookup."""
    now = [100.0]
    monkeypatch.setattr(device_tokens, "_session_index_now", lambda: now[0])
    monkeypatch.setattr(device_tokens, "_SESSION_DEVICE_INDEX_TTL_SECONDS", 10)
    issued = device_tokens.issue(device_name="Abhi's iPhone")
    ws = object()
    transport = SimpleNamespace(_ws=ws)
    device_tokens.register_ws_socket(issued["device_id"], ws)

    assert device_tokens.record_session_transport("runtime-sid", transport) == {
        "device_id": issued["device_id"]
    }
    assert device_tokens.device_identity_for_session("runtime-sid") == {
        "device_id": issued["device_id"]
    }

    now[0] = 111.0
    assert device_tokens.device_identity_for_session("runtime-sid") is None
    assert "runtime-sid" not in device_tokens._session_device_sockets
