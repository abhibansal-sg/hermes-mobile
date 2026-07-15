"""STR-258 — device ownership scoping for the transcript REST routes.

Covers the two REST routes that previously let any authenticated paired
device read any session's transcript / search results:

  GET /api/plugins/hermes-mobile/sessions/{session_id}/messages
  GET /api/plugins/hermes-mobile/sessions/search

For both routes:
  - The owning device keeps full (legacy) access.
  - A non-owner device is denied (403 on /messages; the session is scoped
    out of /search results — no leaked snippet/session_id/title).
  - Shared-token (host-trusted) requests keep the current legacy,
    cross-profile behaviour.

Session ownership is wired directly through
``device_tokens.record_session_transport`` (the plugin-owned
session->device correlation ``_device_owns_session`` reads) rather than
through the gateway's runtime ``_sessions`` dict, since neither route
touches the gateway — only ``dashboard.api._device_owns_session`` gates them.
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from hermes_state import SessionDB
from tests.plugins.hermes_mobile.conftest import load_plugin_module

pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

_PREFIX = "/api/plugins/hermes-mobile"
_SHARED_HEADER = {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}

device_tokens = load_plugin_module("device_tokens")


class _Transport:
    def __init__(self, ws: object) -> None:
        self._ws = ws


@pytest.fixture
def home(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    device_tokens._reset_for_tests()
    yield tmp_path
    device_tokens._reset_for_tests()


@pytest.fixture
def client():
    prev_host = getattr(web_server.app.state, "bound_host", None)
    prev_port = getattr(web_server.app.state, "bound_port", None)
    prev_required = getattr(web_server.app.state, "auth_required", None)
    web_server.app.state.bound_host = "127.0.0.1"
    web_server.app.state.bound_port = 8080
    web_server.app.state.auth_required = False
    c = TestClient(web_server.app, base_url="http://127.0.0.1:8080")
    yield c
    web_server.app.state.bound_host = prev_host
    web_server.app.state.bound_port = prev_port
    web_server.app.state.auth_required = prev_required


@pytest.fixture
def devices(home, wired_token_auth):
    owner = device_tokens.issue(device_name="Owner Phone")
    intruder = device_tokens.issue(device_name="Other Phone")
    return owner, intruder


def _own_session(session_id: str, device_id: str) -> None:
    """Correlate ``session_id`` to ``device_id`` the same way a live mobile
    WS connection would (mirrors test_approval_session_ownership._own_session,
    minus the gateway._sessions wiring neither route under test reads)."""
    ws = object()
    device_tokens.register_ws_socket(device_id, ws)
    device_tokens.record_session_transport(session_id, _Transport(ws))


@pytest.fixture
def transcript_db(tmp_path, monkeypatch):
    """A real, isolated SessionDB with two sessions:

    ``owned-session``  — content unique to it ("the secret plan is quick").
    ``other-session``   — content that also matches q="quick" but must never
                           be attributed to the owner device in these tests.
    """
    db_path = tmp_path / "state.db"
    rw = SessionDB(db_path=db_path)
    now = time.time()

    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("owned-session", "tui", now - 200, "Owned Session"),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        ("owned-session", "user", "the secret plan is quick", now - 190, 1),
    )
    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("other-session", "tui", now - 100, "Other Session"),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        ("other-session", "user", "a different quick topic", now - 90, 1),
    )
    rw._conn.commit()

    cur = rw._conn.cursor()
    SessionDB._rebuild_fts_indexes(cur)
    rw._conn.commit()
    rw._conn.close()

    import hermes_state as hs

    monkeypatch.setattr(hs, "DEFAULT_DB_PATH", db_path, raising=False)
    return db_path


@pytest.fixture
def transcript_db_deep_page(tmp_path, monkeypatch):
    """One owned session with a single (oldest) matching message, plus five
    unowned 'noise' sessions whose matching messages are all newer.

    Under ``sort=newest`` every noise session ranks ahead of the owner's
    single match. This proves pagination scopes to the OWNED subset rather
    than filtering an already-paginated global page: with ``limit=1`` the
    top-of-page match across ALL sessions is a noise session, so a naive
    "fetch page, then filter by ownership" approach hands the owner an empty
    page even though it has a real, owned match further back in the ranking.
    """
    db_path = tmp_path / "state.db"
    rw = SessionDB(db_path=db_path)
    now = time.time()

    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("owned-session", "tui", now - 1000, "Owned Session"),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        ("owned-session", "user", "the secret plan is quick", now - 1000, 1),
    )

    for i in range(5):
        sid = f"noise-session-{i}"
        ts = now - 500 + i
        rw._conn.execute(
            "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
            (sid, "tui", ts, f"Noise Session {i}"),
        )
        rw._conn.execute(
            "INSERT INTO messages (session_id, role, content, timestamp, active)"
            " VALUES (?, ?, ?, ?, ?)",
            (sid, "user", "another quick topic", ts, 1),
        )
    rw._conn.commit()

    cur = rw._conn.cursor()
    SessionDB._rebuild_fts_indexes(cur)
    rw._conn.commit()
    rw._conn.close()

    import hermes_state as hs

    monkeypatch.setattr(hs, "DEFAULT_DB_PATH", db_path, raising=False)
    return db_path


# ---------------------------------------------------------------------------
# GET /sessions/{session_id}/messages
# ---------------------------------------------------------------------------


class TestMessagesOwnership:
    def test_owning_device_succeeds(self, client, devices, transcript_db):
        owner, _intruder = devices
        _own_session("owned-session", owner["device_id"])

        r = client.get(
            f"{_PREFIX}/sessions/owned-session/messages",
            headers={"X-Hermes-Session-Token": owner["token"]},
        )
        assert r.status_code == 200
        assert r.json()["session_id"] == "owned-session"

    def test_non_owner_device_gets_403(self, client, devices, transcript_db):
        owner, intruder = devices
        _own_session("owned-session", owner["device_id"])

        r = client.get(
            f"{_PREFIX}/sessions/owned-session/messages",
            headers={"X-Hermes-Session-Token": intruder["token"]},
        )
        assert r.status_code == 403
        assert r.json() == {"detail": "Device token does not own session"}

    def test_non_owner_device_gets_403_for_unowned_session(
        self, client, devices, transcript_db
    ):
        """A session with no device correlation at all must still fail closed
        for a device-token request (only shared-token/host-trusted requests
        get legacy access to unmapped sessions)."""
        _owner, intruder = devices

        r = client.get(
            f"{_PREFIX}/sessions/other-session/messages",
            headers={"X-Hermes-Session-Token": intruder["token"]},
        )
        assert r.status_code == 403
        assert r.json() == {"detail": "Device token does not own session"}

    def test_shared_token_still_succeeds(self, client, devices, transcript_db):
        owner, _intruder = devices
        _own_session("owned-session", owner["device_id"])

        r = client.get(
            f"{_PREFIX}/sessions/owned-session/messages",
            headers=_SHARED_HEADER,
        )
        assert r.status_code == 200
        assert r.json()["session_id"] == "owned-session"


# ---------------------------------------------------------------------------
# GET /sessions/search
# ---------------------------------------------------------------------------


class TestSearchOwnership:
    def test_owning_device_sees_only_owned_results(self, client, devices, transcript_db):
        owner, _intruder = devices
        _own_session("owned-session", owner["device_id"])

        r = client.get(
            f"{_PREFIX}/sessions/search",
            params={"q": "quick", "limit": 20},
            headers={"X-Hermes-Session-Token": owner["token"]},
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) > 0, "owner must see its own matching session"
        session_ids = {row["session_id"] for row in body["results"]}
        assert session_ids == {"owned-session"}

    def test_non_owner_device_sees_no_leaked_results(
        self, client, devices, transcript_db
    ):
        owner, intruder = devices
        _own_session("owned-session", owner["device_id"])

        r = client.get(
            f"{_PREFIX}/sessions/search",
            params={"q": "quick", "limit": 20},
            headers={"X-Hermes-Session-Token": intruder["token"]},
        )
        assert r.status_code == 200
        body = r.json()
        assert body["results"] == [], (
            f"intruder must not see any results (owned nor unowned), got {body['results']!r}"
        )
        assert body["count"] == 0

    def test_shared_token_sees_legacy_cross_profile_results(
        self, client, devices, transcript_db
    ):
        owner, _intruder = devices
        _own_session("owned-session", owner["device_id"])

        r = client.get(
            f"{_PREFIX}/sessions/search",
            params={"q": "quick", "limit": 20},
            headers=_SHARED_HEADER,
        )
        assert r.status_code == 200
        body = r.json()
        session_ids = {row["session_id"] for row in body["results"]}
        assert session_ids == {"owned-session", "other-session"}

    def test_owning_device_finds_owned_match_ranked_behind_noise(
        self, client, devices, transcript_db_deep_page
    ):
        """Regression: pagination must scope to the OWNED subset, not filter
        an already-paginated global page. All 5 noise sessions' matches are
        newer than (and rank ahead of, under sort=newest) the owner's single
        matching row, so a "fetch top-1 page, then filter by ownership"
        approach returns an empty page here even though the owner has a real
        match — that bug is exactly what this test guards against."""
        owner, _intruder = devices
        _own_session("owned-session", owner["device_id"])

        r = client.get(
            f"{_PREFIX}/sessions/search",
            params={"q": "quick", "limit": 1, "sort": "newest"},
            headers={"X-Hermes-Session-Token": owner["token"]},
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) == 1, (
            "owner must see its owned match even though it ranks behind 5 "
            f"non-owned noise sessions; got {body['results']!r}"
        )
        assert body["results"][0]["session_id"] == "owned-session"
        assert body["count"] == 1

    def test_owning_device_offset_past_owned_matches_returns_empty(
        self, client, devices, transcript_db_deep_page
    ):
        """Offset beyond the number of OWNED matches must return an empty
        page, not wrap around into non-owned noise results."""
        owner, _intruder = devices
        _own_session("owned-session", owner["device_id"])

        r = client.get(
            f"{_PREFIX}/sessions/search",
            params={"q": "quick", "limit": 1, "offset": 1, "sort": "newest"},
            headers={"X-Hermes-Session-Token": owner["token"]},
        )
        assert r.status_code == 200
        body = r.json()
        assert body["results"] == []
        assert body["count"] == 0

    def test_non_owner_device_sees_no_leak_in_deep_page(
        self, client, devices, transcript_db_deep_page
    ):
        """An intruder device (owning nothing) must still see zero results
        even when the owned-only scan has to page deep through noise."""
        owner, intruder = devices
        _own_session("owned-session", owner["device_id"])

        r = client.get(
            f"{_PREFIX}/sessions/search",
            params={"q": "quick", "limit": 1, "sort": "newest"},
            headers={"X-Hermes-Session-Token": intruder["token"]},
        )
        assert r.status_code == 200
        body = r.json()
        assert body["results"] == []
        assert body["count"] == 0
