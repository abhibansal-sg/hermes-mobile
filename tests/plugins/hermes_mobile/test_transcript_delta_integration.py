"""Integrity smoke test for the transcript delta-sync — END TO END against a REAL
``SessionDB``, driving every history-reshape the gateway can actually perform.

This is the "is the delta safe once we turn it on?" test. It does NOT mock the DB:
it creates a real temp ``SessionDB``, drives real ``append_message`` /
``replace_messages`` (retry/compress) / ``rewind_to_message`` (undo), and runs a
``ClientMirror`` that faithfully replays the iOS delta-aware fetch + merge
(``decide_delta`` → ``shape_messages`` → cached-prefix + tail). After EVERY
operation it asserts the single invariant that matters:

    the client's merged cache always converges to the server's authoritative
    active transcript — same ids, same order, no duplicates, no gaps.

If that holds across append / retry / undo / compaction / shaping / garbage
cursors, the delta is integrity-safe to switch on. A second class of tests drives
the ACTUAL FastAPI route over HTTP (auth gate, query-param parsing, response
envelope) so the wire contract is covered too.

Run:  ./.venv/bin/python -m pytest tests/plugins/hermes_mobile/test_transcript_delta_integration.py -q
"""

from __future__ import annotations

import importlib

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module

transcript_sync = load_plugin_module("transcript_sync")

from hermes_state import SessionDB  # real DB code path


# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def db(tmp_path):
    """A real, isolated SessionDB on a temp file (WAL, full schema)."""
    d = SessionDB(db_path=tmp_path / "state.db")
    try:
        yield d
    finally:
        try:
            d._conn.close()
        except Exception:
            pass


def _identity(messages):
    """The integrity-relevant projection: (id, role, content) in order."""
    return [(m.get("id"), m.get("role"), m.get("content")) for m in messages]


class ClientMirror:
    """Faithful replay of the iOS delta-aware fetch + merge (fetchTranscriptDeltaAware
    + CacheStore.deltaCursor + the loadTranscript+tail union)."""

    def __init__(self):
        self.cache = []  # the on-device transcript mirror (list of row dicts)

    def cursor(self):
        wire = [m for m in self.cache if m.get("id") is not None]
        if not wire:
            return (0, -1)  # cold — no cursor
        return (max(m["id"] for m in wire), len(wire))

    def fetch(self, db, sid, shape="full"):
        """One open/reconnect cycle: ask the server for a delta and merge it."""
        server = db.get_messages(sid)  # what the plugin route reads (read-only)
        after_id, prefix_count = self.cursor()
        is_delta, payload, total, max_id = transcript_sync.decide_delta(
            server, after_id, prefix_count
        )
        payload = transcript_sync.shape_messages(payload, shape)
        if is_delta:
            self.cache = self.cache + payload  # cached prefix + tail
        else:
            self.cache = payload  # full re-sync
        return is_delta

    def assert_converged(self, db, sid):
        assert _identity(self.cache) == _identity(db.get_messages(sid)), (
            "client cache diverged from server truth"
        )


def _turn(db, sid, user, assistant, **assistant_kw):
    """Append one user→assistant turn; return (user_id, assistant_id)."""
    uid = db.append_message(sid, role="user", content=user)
    aid = db.append_message(sid, role="assistant", content=assistant, **assistant_kw)
    return uid, aid


# ---------------------------------------------------------------------------
# Scenario matrix — real DB, real reshapes, client convergence
# ---------------------------------------------------------------------------

def test_cold_open_empty_session(db):
    db.create_session("s", source="test")
    c = ClientMirror()
    assert c.fetch(db, "s") is False  # cold → full
    c.assert_converged(db, "s")
    assert c.cache == []


def test_pure_append_serves_delta_and_converges(db):
    db.create_session("s", source="test")
    _turn(db, "s", "hi", "hello")
    c = ClientMirror()
    assert c.fetch(db, "s") is False  # first fetch is cold/full
    c.assert_converged(db, "s")

    # New turn appended server-side → next fetch must be a DELTA, not a full pull.
    _turn(db, "s", "how are you", "great")
    assert c.fetch(db, "s") is True  # delta
    c.assert_converged(db, "s")

    # Several more appends, each a delta, always converging.
    for i in range(5):
        _turn(db, "s", f"q{i}", f"a{i}")
        assert c.fetch(db, "s") is True
        c.assert_converged(db, "s")


def test_no_change_is_empty_delta(db):
    db.create_session("s", source="test")
    _turn(db, "s", "hi", "hello")
    c = ClientMirror()
    c.fetch(db, "s")
    before = list(c.cache)
    assert c.fetch(db, "s") is True  # caught up → delta with empty tail
    assert c.cache == before
    c.assert_converged(db, "s")


def test_retry_replace_messages_forces_full_resync_no_dup(db):
    """/retry path: DELETE + re-INSERT reassigns all ids. The client must NOT
    append the whole new transcript onto its stale cache (would duplicate)."""
    db.create_session("s", source="test")
    _turn(db, "s", "hi", "hello")
    _turn(db, "s", "again", "sure")
    c = ClientMirror()
    c.fetch(db, "s")
    c.assert_converged(db, "s")
    old_ids = [m["id"] for m in c.cache]

    # Retry: re-insert the same logical messages → brand-new autoincrement ids.
    db.replace_messages("s", db.get_messages("s"))
    new_ids = [m["id"] for m in db.get_messages("s")]
    assert new_ids != old_ids  # ids really changed (reshape happened)

    assert c.fetch(db, "s") is False  # cursor row gone → FULL resync
    c.assert_converged(db, "s")
    # No duplication: client has exactly the server's rows, not old+new.
    assert len(c.cache) == len(db.get_messages("s"))


def test_undo_rewind_below_cursor_drops_stale_rows(db):
    db.create_session("s", source="test")
    _turn(db, "s", "one", "a-one")
    uid2, _ = _turn(db, "s", "two", "a-two")
    _turn(db, "s", "three", "a-three")
    c = ClientMirror()
    c.fetch(db, "s")
    c.assert_converged(db, "s")
    assert len(c.cache) == 6

    # Undo back to the 2nd user turn (soft-deletes id >= uid2).
    db.rewind_to_message("s", uid2)
    assert len(db.get_messages("s")) == 2  # only the first turn survives

    c.fetch(db, "s")  # cursor row was rewound → full resync
    c.assert_converged(db, "s")
    assert len(c.cache) == 2  # stale rows dropped, no ghosts


def test_rewind_above_cursor_still_converges(db):
    """Server appended rows the client hasn't seen, then rewound some of THEM.
    The client's cursor row survives, so a delta is served — and must still land
    exactly on the server's surviving tail."""
    db.create_session("s", source="test")
    _turn(db, "s", "one", "a-one")
    c = ClientMirror()
    c.fetch(db, "s")  # client has the first turn (cursor at a-one)
    c.assert_converged(db, "s")

    # Server moves ahead by two turns the client hasn't fetched...
    _turn(db, "s", "two", "a-two")
    uid3, _ = _turn(db, "s", "three", "a-three")
    # ...then undoes the 3rd turn (rows above the client's cursor).
    db.rewind_to_message("s", uid3)

    c.fetch(db, "s")
    c.assert_converged(db, "s")  # delta tail == surviving new rows


def test_prefix_count_mismatch_forces_full_resync(db):
    """A mid-prefix soft-delete keeps the cursor row alive but changes the
    at-or-before count → the guard must full-resync, not serve a wrong delta."""
    db.create_session("s", source="test")
    uid1, _ = _turn(db, "s", "one", "a-one")
    _turn(db, "s", "two", "a-two")
    c = ClientMirror()
    c.fetch(db, "s")
    c.assert_converged(db, "s")

    # Soft-delete the FIRST user row only (mid-prefix), leaving the cursor (last
    # assistant) active but the prefix count smaller. rewind soft-deletes >= id,
    # so to remove just an early row we drive it directly via the active flag.
    db._conn.execute("UPDATE messages SET active = 0 WHERE id = ?", (uid1,))
    assert c.fetch(db, "s") is False  # prefix reshaped → full resync
    c.assert_converged(db, "s")


def test_compaction_new_session_id_cold_full(db):
    """/compress rotates to a NEW session_id. The client opens that id with no
    cursor → cold full fetch. (No cross-session id confusion.)"""
    db.create_session("old", source="test")
    _turn(db, "old", "hi", "hello")
    db.create_session("new", source="test", parent_session_id="old")
    db.append_message("new", role="assistant", content="[compressed summary]")
    _turn(db, "new", "continue", "ok")

    c = ClientMirror()  # fresh client opening the NEW session id
    assert c.fetch(db, "new") is False  # cold → full
    c.assert_converged(db, "new")


def test_skeleton_shape_preserves_ids_and_converges(db):
    """shape=skeleton nulls heavy fields but keeps every row — ids/order/count
    (the cursor's basis) must be unaffected, and the delta still converges."""
    db.create_session("s", source="test")
    _turn(db, "s", "hi", "hello", reasoning_content="X" * 4000,
          tool_calls=[{"id": "t1", "name": "shell"}])
    c = ClientMirror()
    c.fetch(db, "s", shape="skeleton")
    c.assert_converged(db, "s")  # id/role/content match even with heavy fields nulled

    # The heavy fields are elided + flagged on the skeleton rows.
    assistant = [m for m in c.cache if m["role"] == "assistant"][0]
    assert assistant.get("reasoning_content") is None
    assert assistant.get("has_reasoning_content") is True
    assert assistant.get("tool_calls") is None
    assert assistant.get("has_tool_calls") is True

    # A later append fetched as a delta still converges under shaping.
    _turn(db, "s", "more", "sure", reasoning_content="Y" * 4000)
    assert c.fetch(db, "s", shape="skeleton") is True
    c.assert_converged(db, "s")


def test_garbage_cursor_is_safe(db):
    """A corrupt/ahead cursor (id far beyond max, count nonsense) must never
    serve a wrong delta — the guard fails closed to a full resync."""
    db.create_session("s", source="test")
    _turn(db, "s", "hi", "hello")
    c = ClientMirror()
    c.cache = [{"id": 999999, "role": "user", "content": "ghost"}]  # bogus cursor state
    assert c.fetch(db, "s") is False  # cursor not present → full resync
    c.assert_converged(db, "s")


def test_long_session_random_walk_converges(db):
    """Fuzz-ish: a long sequence mixing appends, retries, and undos — the client
    must converge to server truth after EVERY step."""
    db.create_session("s", source="test")
    c = ClientMirror()
    last_user_ids = []
    for step in range(40):
        op = step % 7
        if op in (0, 1, 2, 3):  # mostly appends
            uid, _ = _turn(db, "s", f"u{step}", f"a{step}")
            last_user_ids.append(uid)
        elif op == 4 and db.get_messages("s"):  # retry
            db.replace_messages("s", db.get_messages("s"))
            last_user_ids = [m["id"] for m in db.get_messages("s") if m["role"] == "user"]
        elif op == 5 and len(last_user_ids) >= 2:  # undo to a recent user turn
            target = last_user_ids[-1]
            try:
                db.rewind_to_message("s", target)
            except ValueError:
                pass
            last_user_ids = [m["id"] for m in db.get_messages("s") if m["role"] == "user"]
        # op == 6: just re-fetch (no server change)
        c.fetch(db, "s")
        c.assert_converged(db, "s")


# ---------------------------------------------------------------------------
# HTTP wire contract — the ACTUAL FastAPI route (auth, params, envelope)
# ---------------------------------------------------------------------------

@pytest.fixture
def http(tmp_path, monkeypatch):
    """A TestClient over the real plugin router, reading a temp DB, auth stubbed."""
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    import hermes_state

    db_path = tmp_path / "state.db"
    seed = SessionDB(db_path=db_path)
    seed.create_session("s", source="test")
    seed.append_message("s", role="user", content="hi")
    seed.append_message("s", role="assistant", content="hello",
                        reasoning_content="Z" * 3000)
    seed.append_message("s", role="user", content="more")
    seed.append_message("s", role="assistant", content="sure")
    seed._conn.close()

    # The route reads DEFAULT_DB_PATH read-only — point it at the temp DB.
    monkeypatch.setattr(hermes_state, "DEFAULT_DB_PATH", db_path, raising=False)

    api = load_plugin_module("dashboard.api")
    monkeypatch.setattr(api, "_has_dashboard_api_auth", lambda request: True)

    app = FastAPI()
    app.include_router(api.router, prefix="/api/plugins/hermes-mobile")
    return TestClient(app), api


def test_http_cold_fetch_returns_full(http):
    client, _api = http
    r = client.get("/api/plugins/hermes-mobile/sessions/s/messages")
    assert r.status_code == 200
    body = r.json()
    assert body["is_delta"] is False
    assert body["session_id"] == "s"
    assert len(body["messages"]) == 4
    assert body["prefix_count"] == 4
    assert body["max_id"] == max(m["id"] for m in body["messages"])
    assert body["shape"] == "full"


def test_http_delta_after_cursor(http):
    client, _api = http
    full = client.get("/api/plugins/hermes-mobile/sessions/s/messages").json()
    after = full["max_id"]
    prefix = full["prefix_count"]
    r = client.get(
        f"/api/plugins/hermes-mobile/sessions/s/messages"
        f"?after_id={after}&prefix_count={prefix}"
    )
    body = r.json()
    assert r.status_code == 200
    assert body["is_delta"] is True
    assert body["messages"] == []  # caught up → empty tail


def test_http_skeleton_nulls_heavy_fields(http):
    client, _api = http
    r = client.get("/api/plugins/hermes-mobile/sessions/s/messages?shape=skeleton")
    body = r.json()
    assert body["shape"] == "skeleton"
    assistant = [m for m in body["messages"] if m["role"] == "assistant"][0]
    assert assistant["reasoning_content"] is None
    assert assistant["has_reasoning_content"] is True


def test_http_auth_required(http, monkeypatch):
    client, api = http
    monkeypatch.setattr(api, "_has_dashboard_api_auth", lambda request: False)
    r = client.get("/api/plugins/hermes-mobile/sessions/s/messages")
    assert r.status_code == 401
