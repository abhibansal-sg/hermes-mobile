import asyncio

from hermes_cli import web_server


class _FakeSessionDB:
    """Fake backing the /api/sessions/search endpoint.

    The endpoint surfaces direct session-id matches first, then FTS message
    matches, deduping both by compression lineage root. This fake has no
    compression chains (get_session returns no parent), so each session is its
    own lineage root.
    """

    closed = False

    def search_sessions_by_id(self, query, limit=20, include_archived=True):
        assert query == "20260603"
        assert include_archived is True
        return [
            {
                "id": "20260603_090200_exact",
                "preview": "ID match preview",
                "source": "cli",
                "model": "claude",
                "started_at": 100,
            }
        ]

    def search_messages(self, query, limit=20):
        assert query == "20260603*"
        return [
            {
                "session_id": "20260603_090200_exact",
                "snippet": "duplicate content hit should not replace ID hit",
                "role": "user",
                "source": "cli",
                "model": "claude",
                "session_started": 100,
            },
            {
                "session_id": "content_session",
                "snippet": "content hit",
                "role": "assistant",
                "source": "desktop",
                "model": "gpt",
                "session_started": 200,
            },
        ]

    def get_session(self, session_id):
        # No compression chains in this fixture — every session is its own root.
        return {"id": session_id, "parent_session_id": None}

    def get_compression_tip(self, session_id):
        return session_id

    def close(self):
        self.closed = True


def test_desktop_session_search_merges_id_matches_before_content_matches(monkeypatch):
    monkeypatch.setattr("hermes_state.SessionDB", _FakeSessionDB)

    response = asyncio.run(web_server.search_sessions(q="20260603", limit=2))

    # ID match surfaces first; the content hit on the SAME session is deduped
    # by lineage root (not double-listed); the unrelated content hit follows.
    assert response == {
        "results": [
            {
                "session_id": "20260603_090200_exact",
                "lineage_root": "20260603_090200_exact",
                "snippet": "ID match preview",
                "role": None,
                "source": "cli",
                "model": "claude",
                "session_started": 100,
            },
            {
                "session_id": "content_session",
                "lineage_root": "content_session",
                "snippet": "content hit",
                "role": "assistant",
                "source": "desktop",
                "model": "gpt",
                "session_started": 200,
            },
        ]
    }


class _FakePaginationDB:
    """Fake for offset-pagination tests.

    Returns 5 distinct content-only sessions (s1..s5), each its own lineage
    root (no compression chains). search_sessions_by_id always returns [] so
    this is a pure content-paged scenario.
    """

    closed = False

    _ROWS = [
        {"session_id": f"s{i}", "snippet": f"hit {i}", "role": "user",
         "source": "cli", "model": "claude", "session_started": i * 10}
        for i in range(1, 6)
    ]

    def search_sessions_by_id(self, query, limit=20, include_archived=True):
        # Pure content-paged case — no ID matches.
        return []

    def search_messages(self, query, limit=20):
        # Accept any query string (the route appends '*' wildcards before
        # calling, so we must not assert an exact match).
        return self._ROWS[:limit]

    def get_session(self, session_id):
        return {"id": session_id, "parent_session_id": None}

    def get_compression_tip(self, session_id):
        return session_id

    def close(self):
        self.closed = True


def test_search_sessions_offset_pagination(monkeypatch):
    """Offset slices the deduped result list: non-overlapping pages cover all 5 results."""
    monkeypatch.setattr("hermes_state.SessionDB", _FakePaginationDB)

    page1 = asyncio.run(web_server.search_sessions(q="x", limit=2, offset=0))
    page2 = asyncio.run(web_server.search_sessions(q="x", limit=2, offset=2))
    page3 = asyncio.run(web_server.search_sessions(q="x", limit=2, offset=4))

    ids1 = [r["session_id"] for r in page1["results"]]
    ids2 = [r["session_id"] for r in page2["results"]]
    ids3 = [r["session_id"] for r in page3["results"]]

    # Each page is non-empty.
    assert ids1, "page1 must be non-empty"
    assert ids2, "page2 must be non-empty"
    assert ids3, "page3 must be non-empty"

    # Pages are the expected size (last page has 1 item).
    assert ids1 == ["s1", "s2"], f"page1 expected s1,s2 got {ids1}"
    assert ids2 == ["s3", "s4"], f"page2 expected s3,s4 got {ids2}"
    assert ids3 == ["s5"], f"page3 expected [s5] got {ids3}"

    # No session appears on two pages.
    all_ids = ids1 + ids2 + ids3
    assert len(all_ids) == len(set(all_ids)), "duplicate session_id across pages"

    # Union covers all 5 sessions — nothing skipped.
    assert set(all_ids) == {"s1", "s2", "s3", "s4", "s5"}, \
        f"expected all 5 sessions, got {set(all_ids)}"


class _RecordingFetchLimitDB:
    """Fake that records the ``limit`` passed to ``search_messages``.

    Used to prove a huge ``offset`` is clamped BEFORE it reaches the DB fetch:
    without the cap, offset=10_000 would make fetch_limit ~= 50_000.
    """

    closed = False
    recorded_limits: list

    def __init__(self):
        self.recorded_limits = []

    def search_sessions_by_id(self, query, limit=20, include_archived=True):
        return []

    def search_messages(self, query, limit=20):
        # Record the over-fetch limit the handler derived from window.
        self.recorded_limits.append(limit)
        # Only a couple of shallow rows — nothing exists 10_000 deep.
        return [
            {"session_id": "a", "snippet": "x", "role": "user",
             "source": "cli", "model": "claude", "session_started": 1},
            {"session_id": "b", "snippet": "x", "role": "user",
             "source": "cli", "model": "claude", "session_started": 2},
        ]

    def get_session(self, session_id):
        return {"id": session_id, "parent_session_id": None}

    def get_compression_tip(self, session_id):
        return session_id

    def close(self):
        self.closed = True


def test_search_sessions_offset_capped_bounds_fetch(monkeypatch):
    """A huge offset is clamped (<=500) so the DB over-fetch stays bounded (DoS guard)."""
    fake = _RecordingFetchLimitDB()
    monkeypatch.setattr("hermes_state.SessionDB", lambda *a, **k: fake)

    response = asyncio.run(web_server.search_sessions(q="x", limit=20, offset=10_000))

    # (a) Nothing exists that deep in the fixture → empty page (graceful).
    assert response == {"results": []}

    # (b) The over-fetch limit reached the DB was bounded, NOT ~50_000.
    # Cap: safe_offset<=500 → window<=520 → fetch_limit = window*5 <= 3000.
    assert fake.recorded_limits, "search_messages must have been called"
    assert max(fake.recorded_limits) <= 3000, \
        f"fetch limit not capped: {fake.recorded_limits} (offset was not clamped)"
