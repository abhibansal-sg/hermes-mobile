"""Tests for GET /api/plugins/hermes-mobile/sessions/search.

Covers all six success criteria:

(i)   A query matching content across >=2 sessions returns NON-EMPTY ranked
      results with a non-blank snippet and a populated session_title.
(ii)  limit/offset pagination works.
(iii) role filter (user|assistant) works.
(iv)  A malformed FTS5 query returns a graceful 200-empty result, NOT a 500.
(v)   Missing/empty q -> 400.
(vi)  Request without valid auth -> 401.

All assertions in (i-iii) are LOAD-BEARING — they assert non-empty results
and correct field values. The ``if body['results']:`` guard from the previous
version has been removed: if FTS is unavailable in the test environment the
fixture will fail loudly at setup, not silently skip the assertion.

Fixture pattern (correct, replaces the broken _rebuild_fts_indexes() call):
  1. Open a READ-WRITE SessionDB and insert sessions + messages.
  2. Call ``SessionDB._rebuild_fts_indexes(cursor)`` with an explicit cursor
     (it is a @staticmethod requiring a cursor arg — not a no-arg instance
     method; calling it without cursor raises TypeError).
  3. Commit, close the RW connection.
  4. Monkeypatch DEFAULT_DB_PATH so the route opens this isolated DB.

The endpoint's FIX #1 (_fts_enabled probe) is what makes the route actually
return rows; these tests prove that path is wired correctly.

Run:
  venv/bin/python -m pytest tests/plugins/hermes_mobile/test_session_search_endpoint.py -v
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from hermes_state import SessionDB


# ---------------------------------------------------------------------------
# Helpers / fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def _token_header():
    """Live session-token header; re-read each test so reload() in siblings
    can't leave a stale token."""
    return {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}


@pytest.fixture
def client():
    """TestClient pointed at the plugin router via the full web_server app."""
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
def search_db(tmp_path, monkeypatch):
    """A real, isolated SessionDB with deterministic content across two sessions,
    monkeypatched into DEFAULT_DB_PATH so the route handler opens it.

    Session layout:
      session-alpha  title="Alpha Session"
                     user:      "the quick brown fox"
                     assistant: "the quick fox was seen"
      session-beta   title="Beta Session"
                     user:      "the lazy dog barks"
                     assistant: "the lazy dog was spotted"

    Unique token per session:
      'quick'  -> alpha only (2 rows)
      'lazy'   -> beta only  (2 rows)
      'the'    -> all four rows across both sessions (both roles)
      'barks'  -> beta user only (role filter test anchor)

    FTS rebuild: uses the correct ``SessionDB._rebuild_fts_indexes(cursor)``
    @staticmethod signature (requires an explicit cursor argument).
    """
    db_path = tmp_path / "state.db"
    rw = SessionDB(db_path=db_path)
    now = time.time()

    # Session alpha
    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("session-alpha", "tui", now - 200, "Alpha Session"),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        ("session-alpha", "user", "the quick brown fox", now - 190, 1),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        ("session-alpha", "assistant", "the quick fox was seen", now - 180, 1),
    )

    # Session beta
    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("session-beta", "tui", now - 100, "Beta Session"),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        ("session-beta", "user", "the lazy dog barks", now - 90, 1),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        ("session-beta", "assistant", "the lazy dog was spotted", now - 80, 1),
    )
    rw._conn.commit()

    # Rebuild FTS with the correct @staticmethod signature.
    cur = rw._conn.cursor()
    SessionDB._rebuild_fts_indexes(cur)
    rw._conn.commit()
    rw._conn.close()

    # Patch DEFAULT_DB_PATH so the route opens our isolated DB, not ~/.hermes/state.db.
    import hermes_state as hs
    monkeypatch.setattr(hs, "DEFAULT_DB_PATH", db_path, raising=False)

    return db_path


# ---------------------------------------------------------------------------
# The route URL (relative to app base).
# ---------------------------------------------------------------------------

_SEARCH_URL = "/api/plugins/hermes-mobile/sessions/search"


# ---------------------------------------------------------------------------
# (vi) Auth gate
# ---------------------------------------------------------------------------

class TestAuthGate:
    def test_no_auth_returns_401(self, client):
        r = client.get(_SEARCH_URL, params={"q": "quick"})
        assert r.status_code == 401

    def test_wrong_token_returns_401(self, client):
        r = client.get(
            _SEARCH_URL,
            params={"q": "quick"},
            headers={"X-Hermes-Session-Token": "bad-token"},
        )
        assert r.status_code == 401


# ---------------------------------------------------------------------------
# (v) Missing / empty q -> 400
# ---------------------------------------------------------------------------

class TestMissingQuery:
    def test_no_q_param_returns_400(self, client, _token_header):
        r = client.get(_SEARCH_URL, headers=_token_header)
        assert r.status_code == 400
        assert "q" in r.json().get("error", "").lower()

    def test_empty_q_returns_400(self, client, _token_header):
        r = client.get(_SEARCH_URL, params={"q": ""}, headers=_token_header)
        assert r.status_code == 400

    def test_whitespace_only_q_returns_400(self, client, _token_header):
        r = client.get(_SEARCH_URL, params={"q": "   "}, headers=_token_header)
        assert r.status_code == 400


# ---------------------------------------------------------------------------
# (i) Cross-session ranked results with non-empty snippet + populated title
# ---------------------------------------------------------------------------

class TestCrossSessionSearch:
    def test_query_returns_non_empty_results(
        self, client, _token_header, search_db
    ):
        """'quick' matches two rows in session-alpha; results MUST be non-empty."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "quick", "limit": 20},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert body["query"] == "quick"
        assert isinstance(body["results"], list)
        # LOAD-BEARING: the FTS path must return real rows.
        assert len(body["results"]) > 0, (
            "Expected non-empty results for 'quick'; got 0. "
            "This means _fts_enabled was False (FIX #1 not applied) or the "
            "test fixture failed to rebuild FTS indexes."
        )
        assert body["count"] == len(body["results"])

    def test_query_specific_to_one_session_returns_only_that_session(
        self, client, _token_header, search_db
    ):
        """'quick' only appears in session-alpha — results must be from alpha only."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "quick"},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) > 0, "Expected non-empty results for 'quick'"
        session_ids = {res["session_id"] for res in body["results"]}
        assert session_ids == {"session-alpha"}, (
            f"Expected only session-alpha, got {session_ids}"
        )

    def test_query_matching_multiple_sessions_returns_both(
        self, client, _token_header, search_db
    ):
        """'the' appears in all four rows across both sessions."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "limit": 20},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) >= 2, (
            f"Expected >=2 results for 'the', got {len(body['results'])}"
        )
        session_ids = {res["session_id"] for res in body["results"]}
        assert "session-alpha" in session_ids
        assert "session-beta" in session_ids

    def test_results_have_non_empty_snippet(
        self, client, _token_header, search_db
    ):
        """Every result row must carry a non-blank snippet."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "quick"},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) > 0, "Expected non-empty results"
        for row in body["results"]:
            assert row["snippet"], (
                f"snippet is blank for message_id={row['message_id']}"
            )

    def test_results_have_populated_session_title(
        self, client, _token_header, search_db
    ):
        """session_title must be populated (FIX #2 — separate title lookup)."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "quick"},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) > 0, "Expected non-empty results"
        for row in body["results"]:
            assert row["session_title"], (
                f"session_title is blank for session_id={row['session_id']}. "
                "FIX #2 (separate title lookup) is not applied."
            )
        # The actual title value must match what we inserted.
        alpha_rows = [r for r in body["results"] if r["session_id"] == "session-alpha"]
        assert alpha_rows, "Expected at least one result from session-alpha"
        assert alpha_rows[0]["session_title"] == "Alpha Session"

    def test_response_envelope_uses_count_not_total(
        self, client, _token_header, search_db
    ):
        """Envelope must use 'count' (page size), not 'total'."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "fox"},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert "count" in body, "Response envelope must use 'count', not 'total'"
        assert "total" not in body, "'total' was renamed to 'count'; must be absent"
        assert "query" in body
        assert "results" in body
        assert "offset" in body

    def test_response_result_row_shape(self, client, _token_header, search_db):
        """Every result row has all contracted fields."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "fox"},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) > 0, "Expected non-empty results for 'fox'"
        for row in body["results"]:
            for key in (
                "session_id", "session_title", "session_started_at",
                "message_id", "role", "snippet", "timestamp", "context",
            ):
                assert key in row, f"missing key {key!r} in result row"
            assert isinstance(row["context"], list)


# ---------------------------------------------------------------------------
# (ii) limit / offset pagination
# ---------------------------------------------------------------------------

class TestPagination:
    def test_limit_caps_result_count(self, client, _token_header, search_db):
        """With limit=1 and a query matching >1 rows, we get exactly 1 result."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "limit": 1},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) == 1
        assert body["count"] == 1

    def test_limit_max_clamped_to_100(self, client, _token_header, search_db):
        """limit=9999 is silently clamped to 100; response is 200."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "limit": 9999},
            headers=_token_header,
        )
        assert r.status_code == 200

    def test_offset_advances_window(self, client, _token_header, search_db):
        """Two pages with limit=1 return different rows."""
        r0 = client.get(
            _SEARCH_URL,
            params={"q": "the", "limit": 1, "offset": 0},
            headers=_token_header,
        )
        r1 = client.get(
            _SEARCH_URL,
            params={"q": "the", "limit": 1, "offset": 1},
            headers=_token_header,
        )
        assert r0.status_code == 200
        assert r1.status_code == 200
        # Both pages must have results (we have 4 matching rows).
        assert len(r0.json()["results"]) == 1, "page 0 must have a result"
        assert len(r1.json()["results"]) == 1, "page 1 must have a result"
        ids0 = [x["message_id"] for x in r0.json()["results"]]
        ids1 = [x["message_id"] for x in r1.json()["results"]]
        assert ids0 != ids1, f"page 0 and page 1 returned the same row: {ids0}"

    def test_offset_past_end_returns_empty(self, client, _token_header, search_db):
        """A very high offset returns an empty results list, not an error."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "offset": 9999},
            headers=_token_header,
        )
        assert r.status_code == 200
        assert r.json()["results"] == []
        assert r.json()["count"] == 0


# ---------------------------------------------------------------------------
# (iii) role filter
# ---------------------------------------------------------------------------

class TestRoleFilter:
    def test_role_user_returns_only_user_messages(
        self, client, _token_header, search_db
    ):
        """role=user must return >=1 row and none may be 'assistant'."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "role": "user"},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) > 0, "Expected non-empty results for role=user"
        for row in body["results"]:
            assert row["role"] == "user", (
                f"role filter violated: got role={row['role']!r}"
            )

    def test_role_assistant_returns_only_assistant_messages(
        self, client, _token_header, search_db
    ):
        """role=assistant must return >=1 row and none may be 'user'."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "role": "assistant"},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) > 0, "Expected non-empty results for role=assistant"
        for row in body["results"]:
            assert row["role"] == "assistant", (
                f"role filter violated: got role={row['role']!r}"
            )

    def test_no_role_filter_returns_both_roles(
        self, client, _token_header, search_db
    ):
        """Without a role filter, both user and assistant messages appear."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "limit": 20},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) >= 2, "Expected >=2 results without role filter"
        roles = {row["role"] for row in body["results"]}
        assert "user" in roles, "Expected user messages in unfiltered results"
        assert "assistant" in roles, "Expected assistant messages in unfiltered results"


# ---------------------------------------------------------------------------
# (iv) Malformed FTS5 query — graceful 200 empty, NOT a 500
# ---------------------------------------------------------------------------

class TestMalformedQuery:
    def test_unbalanced_quote_returns_200(self, client, _token_header, search_db):
        """An unbalanced quote is a common FTS5 syntax error; must not 500."""
        r = client.get(
            _SEARCH_URL,
            params={"q": '"unbalanced'},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert isinstance(body["results"], list)

    def test_lone_and_operator_returns_200(self, client, _token_header, search_db):
        """A bare AND with nothing to combine must not 500."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "AND"},
            headers=_token_header,
        )
        assert r.status_code == 200
        assert isinstance(r.json()["results"], list)

    def test_lone_or_operator_returns_200(self, client, _token_header, search_db):
        r = client.get(
            _SEARCH_URL,
            params={"q": "OR"},
            headers=_token_header,
        )
        assert r.status_code == 200
        assert isinstance(r.json()["results"], list)

    def test_repeated_special_chars_returns_200(self, client, _token_header, search_db):
        """FTS5 rejects stray colons, stars in some positions, etc."""
        for bad_q in ("***", "::::", "* OR *", '""""""'):
            r = client.get(
                _SEARCH_URL,
                params={"q": bad_q},
                headers=_token_header,
            )
            assert r.status_code == 200, (
                f"Expected 200 for q={bad_q!r}, got {r.status_code}"
            )
            assert isinstance(r.json()["results"], list)


# ---------------------------------------------------------------------------
# sort parameter
# ---------------------------------------------------------------------------

class TestSortParameter:
    def test_sort_newest_accepted(self, client, _token_header, search_db):
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "sort": "newest"},
            headers=_token_header,
        )
        assert r.status_code == 200
        assert len(r.json()["results"]) > 0

    def test_sort_oldest_accepted(self, client, _token_header, search_db):
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "sort": "oldest"},
            headers=_token_header,
        )
        assert r.status_code == 200
        assert len(r.json()["results"]) > 0

    def test_sort_unknown_falls_back_gracefully(self, client, _token_header, search_db):
        """An unknown sort value must not error — falls back to BM25 rank."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "sort": "totally_invalid"},
            headers=_token_header,
        )
        assert r.status_code == 200

    def test_sort_newest_returns_newer_message_first(
        self, client, _token_header, search_db
    ):
        """With sort=newest the timestamps must be non-increasing."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "sort": "newest", "limit": 20},
            headers=_token_header,
        )
        assert r.status_code == 200
        results = r.json()["results"]
        assert len(results) >= 2, "Need >=2 results to verify ordering"
        timestamps = [row["timestamp"] for row in results]
        assert timestamps == sorted(timestamps, reverse=True), (
            f"sort=newest did not return descending timestamps: {timestamps}"
        )

    def test_sort_oldest_returns_older_message_first(
        self, client, _token_header, search_db
    ):
        """With sort=oldest the timestamps must be non-decreasing."""
        r = client.get(
            _SEARCH_URL,
            params={"q": "the", "sort": "oldest", "limit": 20},
            headers=_token_header,
        )
        assert r.status_code == 200
        results = r.json()["results"]
        assert len(results) >= 2, "Need >=2 results to verify ordering"
        timestamps = [row["timestamp"] for row in results]
        assert timestamps == sorted(timestamps), (
            f"sort=oldest did not return ascending timestamps: {timestamps}"
        )
