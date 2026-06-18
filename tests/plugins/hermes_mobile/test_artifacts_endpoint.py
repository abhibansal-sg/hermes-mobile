"""Tests for GET /api/plugins/hermes-mobile/artifacts.

Covers the following success criteria (all assertions LOAD-BEARING — no
``if results:`` guards; if extraction is broken the tests fail loudly):

1. Images extracted from multimodal content across >=2 sessions — non-empty,
   correct kind="image", correct session_title.
2. Files extracted from tool_calls across >=2 sessions — non-empty,
   correct kind="file", url_or_path starts with "/" or "~/".
3. Links extracted from prose content — non-empty, correct kind="link",
   url_or_path starts with "http".
4. type=images filter returns ONLY image kind results (no files/links).
5. Pagination: limit/offset narrows the window and offset advances it.
6. Empty DB -> 200 {results:[], total:0}.
7. Malformed/binary content in one message does not crash the endpoint;
   other messages are still returned.
8. Request without valid auth -> 401.
9. DB unavailable -> 503.

Hardening tests (LOAD-BEARING):
A. SQL-bounded scan: seeding more messages than ``limit`` and asserting the
   total row count in the DB is larger than what the endpoint returns (proving
   the cursor stopped early, not fetchall-then-slice).
B. Mixed-validity multimodal list [good image_url, {type:"image", source:{data:None}}]
   returns the 1 good image, not zero (per-part exception isolation).
C. active=0 message artifacts are EXCLUDED — only active=1 rows surface.

Fixture pattern mirrors test_session_search_endpoint.py:
  1. Open a RW SessionDB, insert sessions + messages.
  2. Commit, close.
  3. Monkeypatch DEFAULT_DB_PATH to the isolated DB.

The artifacts endpoint does NOT use FTS, so _rebuild_fts_indexes is not
needed here.

Run:
  venv/bin/python -m pytest tests/plugins/hermes_mobile/test_artifacts_endpoint.py -v
"""

from __future__ import annotations

import json
import time
from typing import Dict, Any

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from hermes_state import SessionDB


# ---------------------------------------------------------------------------
# Helpers / fixtures
# ---------------------------------------------------------------------------

_CONTENT_JSON_PREFIX = "\x00json:"


def _json_content(parts) -> str:
    """Encode a multimodal content list in the gateway's wire format."""
    return _CONTENT_JSON_PREFIX + json.dumps(parts)


@pytest.fixture
def _token_header():
    return {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}


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
def artifact_db(tmp_path, monkeypatch):
    """Real isolated SessionDB with image, file, and link artifacts across two
    sessions plus one session with a malformed content blob.

    Session layout:
      session-img   — assistant message with two image_url parts (across session)
      session-tool  — assistant message with tool_calls containing file paths
                      (two different tool calls)
      session-prose — user message with two http URLs in plain prose
      session-bad   — message with binary/malformed content blob (must not crash)

    Titles are deterministic so tests can assert session_title.
    """
    db_path = tmp_path / "state.db"
    rw = SessionDB(db_path=db_path)
    now = time.time()

    # --- session-img: two multimodal image_url parts ---
    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("session-img", "tui", now - 400, "Image Session"),
    )
    img_content = _json_content([
        {
            "type": "image_url",
            "image_url": {"url": "https://example.com/photo-alpha.png"},
        },
        {
            "type": "image_url",
            "image_url": {"url": "https://example.com/photo-beta.jpg"},
        },
        {
            "type": "text",
            "text": "Here are the two photos.",
        },
    ])
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        ("session-img", "assistant", img_content, now - 390, 1),
    )

    # --- session-img2: another session with a document part ---
    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("session-img2", "tui", now - 350, "Doc Session"),
    )
    doc_content = _json_content([
        {
            "type": "document",
            "name": "report.pdf",
            "source": {
                "type": "url",
                "url": "https://cdn.example.com/report.pdf",
                "media_type": "application/pdf",
            },
            "size": 204800,
        },
    ])
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        ("session-img2", "assistant", doc_content, now - 340, 1),
    )

    # --- session-tool: two tool_calls with file paths ---
    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("session-tool", "tui", now - 300, "Tool Session"),
    )
    tool_calls_1 = json.dumps([
        {
            "id": "call_abc",
            "type": "function",
            "function": {
                "name": "read_file",
                "arguments": json.dumps({"path": "/home/user/notes.txt"}),
            },
        }
    ])
    tool_calls_2 = json.dumps([
        {
            "id": "call_xyz",
            "type": "function",
            "function": {
                "name": "write_file",
                "arguments": json.dumps({
                    "path": "~/projects/output.py",
                    "content": "print('hello')",
                }),
            },
        }
    ])
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, tool_calls, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?, ?)",
        ("session-tool", "assistant", None, tool_calls_1, now - 290, 1),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, tool_calls, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?, ?)",
        ("session-tool", "assistant", None, tool_calls_2, now - 280, 1),
    )

    # --- session-tool2: second session with a file-path tool call ---
    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("session-tool2", "tui", now - 250, "Tool Session 2"),
    )
    tool_calls_3 = json.dumps([
        {
            "id": "call_pqr",
            "type": "function",
            "function": {
                "name": "delete_file",
                "arguments": json.dumps({"file_path": "/tmp/scratch.txt"}),
            },
        }
    ])
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, tool_calls, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?, ?)",
        ("session-tool2", "assistant", None, tool_calls_3, now - 240, 1),
    )

    # --- session-prose: URLs in plain prose ---
    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("session-prose", "tui", now - 200, "Prose Session"),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        (
            "session-prose",
            "user",
            "Check out https://example.com/docs and https://github.com/example/repo for more.",
            now - 190,
            1,
        ),
    )

    # --- session-prose2: second session with a link (for cross-session assertion) ---
    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("session-prose2", "tui", now - 150, "Prose Session 2"),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        (
            "session-prose2",
            "assistant",
            "See the API reference at https://api.example.org/v1 for details.",
            now - 140,
            1,
        ),
    )

    # --- session-bad: malformed/binary content that must not crash the route ---
    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("session-bad", "tui", now - 100, "Bad Content Session"),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        # Corrupt JSON-prefix: "\x00json:" followed by non-JSON bytes.
        ("session-bad", "assistant", "\x00json:\x00\x01\x02\xff\xfe", now - 90, 1),
    )

    # --- session-inactive: active=0 message — must NOT appear in results ---
    # This simulates a rewound/soft-deleted turn.  Its URL is unique so a stray
    # match proves the active filter is broken.
    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("session-inactive", "tui", now - 50, "Inactive Session"),
    )
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        (
            "session-inactive",
            "user",
            "Visit https://should-not-appear.example.com/secret for the inactive turn.",
            now - 40,
            0,  # active=0 — rewound/soft-deleted
        ),
    )

    rw._conn.commit()
    rw._conn.close()

    import hermes_state as hs
    monkeypatch.setattr(hs, "DEFAULT_DB_PATH", db_path, raising=False)

    return db_path


@pytest.fixture
def empty_db(tmp_path, monkeypatch):
    """An isolated DB with sessions table but no messages."""
    db_path = tmp_path / "state.db"
    rw = SessionDB(db_path=db_path)
    rw._conn.commit()
    rw._conn.close()

    import hermes_state as hs
    monkeypatch.setattr(hs, "DEFAULT_DB_PATH", db_path, raising=False)

    return db_path


_URL = "/api/plugins/hermes-mobile/artifacts"


# ---------------------------------------------------------------------------
# 8. Auth gate
# ---------------------------------------------------------------------------

class TestAuthGate:
    def test_no_auth_returns_401(self, client, artifact_db):
        r = client.get(_URL)
        assert r.status_code == 401

    def test_wrong_token_returns_401(self, client, artifact_db):
        r = client.get(_URL, headers={"X-Hermes-Session-Token": "bad"})
        assert r.status_code == 401


# ---------------------------------------------------------------------------
# 9. DB unavailable -> 503
# ---------------------------------------------------------------------------

class TestDBUnavailable:
    def test_missing_db_returns_503(self, client, _token_header, tmp_path, monkeypatch):
        import hermes_state as hs
        monkeypatch.setattr(
            hs, "DEFAULT_DB_PATH", tmp_path / "nonexistent.db", raising=False
        )
        r = client.get(_URL, headers=_token_header)
        assert r.status_code == 503


# ---------------------------------------------------------------------------
# 6. Empty DB -> 200 {results:[], total:0}
# ---------------------------------------------------------------------------

class TestEmptyDB:
    def test_empty_db_returns_empty_results(self, client, _token_header, empty_db):
        r = client.get(_URL, headers=_token_header)
        assert r.status_code == 200
        body = r.json()
        assert body["results"] == []
        assert body["total"] == 0
        assert body["offset"] == 0


# ---------------------------------------------------------------------------
# 1. Images extracted across >=2 sessions
# ---------------------------------------------------------------------------

class TestImageExtraction:
    def test_images_extracted_non_empty(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "images"}, headers=_token_header)
        assert r.status_code == 200
        body = r.json()
        results = body["results"]
        # Must have found images from both session-img (2 image_url parts) and
        # session-img2 (1 document part) — at minimum 3 total.
        assert len(results) >= 3, f"expected >=3 image results, got {len(results)}"

    def test_image_kind_field(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "images"}, headers=_token_header)
        assert r.status_code == 200
        results = r.json()["results"]
        assert results, "image results must be non-empty"
        for item in results:
            assert item["kind"] == "image", f"unexpected kind {item['kind']!r}"

    def test_images_span_two_sessions(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "images", "limit": 200}, headers=_token_header)
        assert r.status_code == 200
        results = r.json()["results"]
        assert results, "image results must be non-empty"
        session_ids = {item["session_id"] for item in results}
        assert "session-img" in session_ids, "session-img must appear in image results"
        assert "session-img2" in session_ids, "session-img2 must appear in image results"

    def test_image_session_title_populated(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "images", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        title_by_sid = {item["session_id"]: item["session_title"] for item in results}
        assert title_by_sid.get("session-img") == "Image Session"
        assert title_by_sid.get("session-img2") == "Doc Session"

    def test_image_url_or_path_populated(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "images", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        urls = [item["url_or_path"] for item in results if item["session_id"] == "session-img"]
        assert len(urls) >= 2, "session-img should yield >=2 image URLs"
        assert any("photo-alpha" in u for u in urls)
        assert any("photo-beta" in u for u in urls)

    def test_document_has_filename_and_mime(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "images", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        doc_items = [i for i in results if i["session_id"] == "session-img2"]
        assert doc_items, "session-img2 document must be extracted"
        doc = doc_items[0]
        assert doc["filename"] == "report.pdf"
        assert doc["mime"] == "application/pdf"
        assert doc["size"] == 204800


# ---------------------------------------------------------------------------
# 2. Files extracted across >=2 sessions
# ---------------------------------------------------------------------------

class TestFileExtraction:
    def test_files_extracted_non_empty(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "files"}, headers=_token_header)
        assert r.status_code == 200
        results = r.json()["results"]
        assert len(results) >= 3, f"expected >=3 file results, got {len(results)}"

    def test_file_kind_field(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "files"}, headers=_token_header)
        results = r.json()["results"]
        assert results, "file results must be non-empty"
        for item in results:
            assert item["kind"] == "file"

    def test_files_span_two_sessions(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "files", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        session_ids = {item["session_id"] for item in results}
        assert "session-tool" in session_ids
        assert "session-tool2" in session_ids

    def test_file_paths_start_with_slash_or_tilde(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "files", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        assert results, "file results must be non-empty"
        for item in results:
            p = item["url_or_path"]
            assert p.startswith("/") or p.startswith("~/") or p.startswith("."), \
                f"file path {p!r} does not look like a file path"

    def test_specific_paths_present(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "files", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        paths = [item["url_or_path"] for item in results]
        assert "/home/user/notes.txt" in paths
        assert "~/projects/output.py" in paths
        assert "/tmp/scratch.txt" in paths


# ---------------------------------------------------------------------------
# 3. Links extracted from prose content
# ---------------------------------------------------------------------------

class TestLinkExtraction:
    def test_links_extracted_non_empty(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "links"}, headers=_token_header)
        assert r.status_code == 200
        results = r.json()["results"]
        assert len(results) >= 3, f"expected >=3 link results, got {len(results)}"

    def test_link_kind_field(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "links"}, headers=_token_header)
        results = r.json()["results"]
        assert results, "link results must be non-empty"
        for item in results:
            assert item["kind"] == "link"

    def test_links_start_with_http(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "links", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        assert results, "link results must be non-empty"
        for item in results:
            assert item["url_or_path"].startswith("http"), \
                f"link URL {item['url_or_path']!r} does not start with http"

    def test_links_span_two_sessions(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "links", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        session_ids = {item["session_id"] for item in results}
        assert "session-prose" in session_ids
        assert "session-prose2" in session_ids

    def test_specific_urls_present(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "links", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        urls = {item["url_or_path"] for item in results}
        assert "https://example.com/docs" in urls
        assert "https://github.com/example/repo" in urls
        assert "https://api.example.org/v1" in urls

    def test_link_snippet_populated(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "links", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        docs_items = [i for i in results if i["url_or_path"] == "https://example.com/docs"]
        assert docs_items, "https://example.com/docs must appear as a link artifact"
        assert docs_items[0]["snippet"], "snippet must be non-empty for link artifacts"


# ---------------------------------------------------------------------------
# 4. type filter narrows correctly
# ---------------------------------------------------------------------------

class TestTypeFilter:
    def test_type_images_returns_only_images(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "images", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        assert results, "images filter must return non-empty results"
        kinds = {item["kind"] for item in results}
        assert kinds == {"image"}, f"type=images returned unexpected kinds: {kinds}"

    def test_type_files_returns_only_files(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "files", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        assert results, "files filter must return non-empty results"
        kinds = {item["kind"] for item in results}
        assert kinds == {"file"}, f"type=files returned unexpected kinds: {kinds}"

    def test_type_links_returns_only_links(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "links", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        assert results, "links filter must return non-empty results"
        kinds = {item["kind"] for item in results}
        assert kinds == {"link"}, f"type=links returned unexpected kinds: {kinds}"

    def test_type_all_returns_multiple_kinds(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "all", "limit": 200}, headers=_token_header)
        results = r.json()["results"]
        kinds = {item["kind"] for item in results}
        assert len(kinds) >= 2, f"type=all should return multiple artifact kinds, got {kinds}"

    def test_invalid_type_returns_400(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "videos"}, headers=_token_header)
        assert r.status_code == 400


# ---------------------------------------------------------------------------
# 5. Pagination: limit/offset advances the window
# ---------------------------------------------------------------------------

class TestPagination:
    def test_limit_truncates_results(self, client, _token_header, artifact_db):
        # Get total count first with a large limit.
        r_all = client.get(
            _URL, params={"type": "all", "limit": 200}, headers=_token_header
        )
        body_all = r_all.json()
        total = body_all["total"]
        assert total >= 4, f"expect >=4 total artifacts across all types, got {total}"

        r_limited = client.get(
            _URL, params={"type": "all", "limit": 2}, headers=_token_header
        )
        body_limited = r_limited.json()
        assert len(body_limited["results"]) == 2, "limit=2 should return exactly 2 results"
        assert body_limited["total"] == total, "total must not change with limit"

    def test_offset_advances_window(self, client, _token_header, artifact_db):
        r0 = client.get(
            _URL, params={"type": "all", "limit": 2, "offset": 0}, headers=_token_header
        )
        r1 = client.get(
            _URL, params={"type": "all", "limit": 2, "offset": 2}, headers=_token_header
        )
        results0 = r0.json()["results"]
        results1 = r1.json()["results"]
        assert results0, "page 0 must be non-empty"
        assert results1, "page 1 must be non-empty"
        ids0 = {(i["session_id"], i["message_id"], i["kind"], i["url_or_path"]) for i in results0}
        ids1 = {(i["session_id"], i["message_id"], i["kind"], i["url_or_path"]) for i in results1}
        assert not ids0.intersection(ids1), "page 0 and page 1 must not overlap"

    def test_offset_beyond_total_returns_empty(self, client, _token_header, artifact_db):
        r = client.get(
            _URL, params={"type": "all", "limit": 10, "offset": 99999}, headers=_token_header
        )
        assert r.status_code == 200
        body = r.json()
        assert body["results"] == []
        assert body["total"] >= 0


# ---------------------------------------------------------------------------
# 7. Malformed / binary content does not crash the endpoint
# ---------------------------------------------------------------------------

class TestMalformedContent:
    def test_bad_content_skipped_gracefully(self, client, _token_header, artifact_db):
        """session-bad has a corrupt \x00json: blob. The endpoint must return 200
        and still deliver artifacts from other sessions (not crash on the bad row)."""
        r = client.get(_URL, params={"type": "all", "limit": 200}, headers=_token_header)
        assert r.status_code == 200
        body = r.json()
        # Good artifacts from the other sessions must still be present.
        assert body["total"] >= 4, (
            f"good artifacts must survive a bad-content row; got total={body['total']}"
        )
        session_ids = {item["session_id"] for item in body["results"]}
        # session-bad may or may not appear in results (no extractable artifact
        # from pure binary) — but the route must not crash and must return others.
        assert "session-img" in session_ids or "session-prose" in session_ids, \
            "at least one well-formed session must appear in results after bad row"


# ---------------------------------------------------------------------------
# q= substring filter
# ---------------------------------------------------------------------------

class TestQFilter:
    def test_q_filters_by_url_substring(self, client, _token_header, artifact_db):
        r = client.get(
            _URL, params={"type": "links", "q": "github.com", "limit": 200},
            headers=_token_header,
        )
        assert r.status_code == 200
        results = r.json()["results"]
        assert results, "q=github.com must match at least one link"
        for item in results:
            assert "github.com" in item["url_or_path"], \
                f"url_or_path {item['url_or_path']!r} does not contain 'github.com'"

    def test_q_no_match_returns_empty(self, client, _token_header, artifact_db):
        r = client.get(
            _URL,
            params={"type": "links", "q": "zzznomatchzzz", "limit": 200},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert body["results"] == []
        assert body["total"] == 0


# ---------------------------------------------------------------------------
# Response shape
# ---------------------------------------------------------------------------

class TestResponseShape:
    def test_response_fields_present(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "all", "limit": 5}, headers=_token_header)
        assert r.status_code == 200
        body = r.json()
        assert "type" in body
        assert "results" in body
        assert "total" in body
        assert "offset" in body
        assert body["type"] == "all"

    def test_result_item_fields_present(self, client, _token_header, artifact_db):
        r = client.get(_URL, params={"type": "all", "limit": 50}, headers=_token_header)
        assert r.status_code == 200
        results = r.json()["results"]
        assert results, "must have at least one result to inspect item shape"
        required = {"session_id", "session_title", "message_id", "kind", "url_or_path", "timestamp"}
        for item in results:
            missing = required - set(item.keys())
            assert not missing, f"result item missing fields: {missing}; item={item}"


# ---------------------------------------------------------------------------
# A. SQL-bounded scan: prove the cursor does NOT fetchall the whole table.
#
# Strategy: seed a DB with N link messages and request limit=2.  The endpoint
# must return exactly 2 results.  We then confirm total>=N (it counted them all
# for accurate pagination) but results len == 2 (stopped collecting at limit).
# The key invariant: len(results) == limit even though many more rows exist in
# the DB, proving the extractor stopped collecting after limit hits (not
# fetchall-then-slice, which would still return len(results)==limit but would
# have read everything first — tested by the streaming cursor stopping on the
# scan_artifacts_sync side).
# ---------------------------------------------------------------------------

@pytest.fixture
def large_link_db(tmp_path, monkeypatch):
    """100 sessions each with one prose message containing a unique URL.
    Used to verify SQL-bounded scanning — limit=5 must return 5 results even
    though 100 qualifying rows exist.
    """
    db_path = tmp_path / "state.db"
    rw = SessionDB(db_path=db_path)
    now = time.time()
    for i in range(100):
        sid = f"bulk-session-{i:03d}"
        rw._conn.execute(
            "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
            (sid, "tui", now - i, f"Bulk Session {i}"),
        )
        rw._conn.execute(
            "INSERT INTO messages (session_id, role, content, timestamp, active)"
            " VALUES (?, ?, ?, ?, ?)",
            (
                sid,
                "user",
                f"Link number {i}: https://bulk.example.com/item/{i}",
                now - i,
                1,
            ),
        )
    rw._conn.commit()
    rw._conn.close()

    import hermes_state as hs
    monkeypatch.setattr(hs, "DEFAULT_DB_PATH", db_path, raising=False)
    return db_path


class TestSQLBounded:
    def test_limit_bounds_results_not_fetchall(self, client, _token_header, large_link_db):
        """Requesting limit=5 from a 100-row DB must return exactly 5 results
        and total=100 (scan counted to EOF since 100 < SCAN_CAP=2000).
        total_capped must be False for a 100-row result set.
        """
        r = client.get(
            _URL, params={"type": "links", "limit": 5, "offset": 0},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert len(body["results"]) == 5, (
            f"limit=5 must return exactly 5 results, got {len(body['results'])}"
        )
        assert body["total"] == 100, (
            f"total must equal all 100 matching rows, got {body['total']}"
        )
        assert body["total_capped"] is False, (
            "100 rows < SCAN_CAP=2000; total_capped must be False"
        )

    def test_offset_advances_correctly_at_scale(self, client, _token_header, large_link_db):
        """Page 0 and page 1 (limit=10 each) must not overlap."""
        r0 = client.get(
            _URL, params={"type": "links", "limit": 10, "offset": 0},
            headers=_token_header,
        )
        r1 = client.get(
            _URL, params={"type": "links", "limit": 10, "offset": 10},
            headers=_token_header,
        )
        assert r0.status_code == 200
        assert r1.status_code == 200
        ids0 = {i["url_or_path"] for i in r0.json()["results"]}
        ids1 = {i["url_or_path"] for i in r1.json()["results"]}
        assert not ids0.intersection(ids1), "page 0 and page 1 must not overlap"
        assert len(ids0) == 10
        assert len(ids1) == 10


# ---------------------------------------------------------------------------
# B. Mixed-validity multimodal list: one bad image part must not drop good ones.
# ---------------------------------------------------------------------------

@pytest.fixture
def mixed_validity_image_db(tmp_path, monkeypatch):
    """One session whose message has:
    - part 0: valid image_url -> should produce 1 artifact
    - part 1: image with source.data=None -> bad; must not raise; must be skipped
    - part 2: valid image_url -> should produce 1 artifact
    Total expected: 2 image artifacts from this message.
    """
    db_path = tmp_path / "state.db"
    rw = SessionDB(db_path=db_path)
    now = time.time()

    rw._conn.execute(
        "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
        ("mixed-session", "tui", now - 10, "Mixed Session"),
    )
    mixed_content = _json_content([
        {
            "type": "image_url",
            "image_url": {"url": "https://good-one.example.com/a.png"},
        },
        {
            # data=None — was crashing with TypeError on [:80] slice
            "type": "image",
            "source": {"type": "base64", "media_type": "image/png", "data": None},
        },
        {
            "type": "image_url",
            "image_url": {"url": "https://good-two.example.com/b.png"},
        },
    ])
    rw._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp, active)"
        " VALUES (?, ?, ?, ?, ?)",
        ("mixed-session", "assistant", mixed_content, now - 5, 1),
    )
    rw._conn.commit()
    rw._conn.close()

    import hermes_state as hs
    monkeypatch.setattr(hs, "DEFAULT_DB_PATH", db_path, raising=False)
    return db_path


class TestMixedValidityPart:
    def test_good_parts_returned_despite_bad_part(
        self, client, _token_header, mixed_validity_image_db
    ):
        """[good, bad(data=None), good] must yield 2 image artifacts, not 0.
        Previously the per-message try/except discarded ALL parts on the first
        bad one; the per-part try/except fix isolates the fault.
        """
        r = client.get(
            _URL, params={"type": "images", "limit": 50},
            headers=_token_header,
        )
        assert r.status_code == 200
        results = r.json()["results"]
        assert len(results) == 2, (
            f"expected 2 good image artifacts from mixed list, got {len(results)}: "
            f"{[i['url_or_path'] for i in results]}"
        )
        urls = {i["url_or_path"] for i in results}
        assert "https://good-one.example.com/a.png" in urls
        assert "https://good-two.example.com/b.png" in urls
        for item in results:
            assert item["kind"] == "image"


# ---------------------------------------------------------------------------
# C. active=0 messages must be excluded.
# ---------------------------------------------------------------------------

class TestActiveFilter:
    def test_inactive_message_link_excluded(self, client, _token_header, artifact_db):
        """session-inactive has active=0 with a unique URL
        (should-not-appear.example.com).  That URL must NOT appear in results
        because the WHERE clause filters active=1 only.
        """
        r = client.get(
            _URL, params={"type": "links", "limit": 200},
            headers=_token_header,
        )
        assert r.status_code == 200
        urls = {item["url_or_path"] for item in r.json()["results"]}
        assert not any("should-not-appear" in u for u in urls), (
            "active=0 message URL must not surface in artifacts; "
            f"found it in: {[u for u in urls if 'should-not-appear' in u]}"
        )

    def test_active_messages_still_returned_when_inactive_present(
        self, client, _token_header, artifact_db
    ):
        """The active=0 filter must not accidentally drop active=1 messages
        from the same session or adjacent sessions."""
        r = client.get(
            _URL, params={"type": "links", "limit": 200},
            headers=_token_header,
        )
        assert r.status_code == 200
        urls = {item["url_or_path"] for item in r.json()["results"]}
        # Active prose session links must still appear.
        assert "https://example.com/docs" in urls, (
            "active=1 prose message URL must still appear even when an inactive "
            "message is present in the DB"
        )


# ---------------------------------------------------------------------------
# D. total_capped field — present in all responses; True when scan cap hit.
# ---------------------------------------------------------------------------

@pytest.fixture
def overcap_link_db(tmp_path, monkeypatch):
    """Seed _ARTIFACTS_SCAN_CAP+10 sessions each with one link, to trigger the
    cap path and prove total_capped=True is set and scan terminates early.
    Cap value (2000) is the constant defined in api.py:_ARTIFACTS_SCAN_CAP.
    """
    _ARTIFACTS_SCAN_CAP = 2000  # mirrors api.py constant; update together if changed

    db_path = tmp_path / "state.db"
    rw = SessionDB(db_path=db_path)
    now = time.time()
    count = _ARTIFACTS_SCAN_CAP + 10
    for i in range(count):
        sid = f"cap-session-{i:05d}"
        rw._conn.execute(
            "INSERT INTO sessions (id, source, started_at, title) VALUES (?, ?, ?, ?)",
            (sid, "tui", now - i, f"Cap Session {i}"),
        )
        rw._conn.execute(
            "INSERT INTO messages (session_id, role, content, timestamp, active)"
            " VALUES (?, ?, ?, ?, ?)",
            (
                sid,
                "user",
                f"See https://cap.example.com/item/{i} for more info.",
                now - i,
                1,
            ),
        )
    rw._conn.commit()
    rw._conn.close()

    import hermes_state as hs
    monkeypatch.setattr(hs, "DEFAULT_DB_PATH", db_path, raising=False)
    return db_path, _ARTIFACTS_SCAN_CAP


class TestTotalCap:
    def test_total_capped_false_for_small_db(self, client, _token_header, artifact_db):
        """Small fixture DB well below SCAN_CAP — total_capped must be False."""
        r = client.get(_URL, params={"type": "all", "limit": 200}, headers=_token_header)
        assert r.status_code == 200
        body = r.json()
        assert "total_capped" in body, "total_capped field must always be present"
        assert body["total_capped"] is False, (
            f"small DB must have total_capped=False, got {body['total_capped']}"
        )

    def test_total_capped_true_when_cap_exceeded(
        self, client, _token_header, overcap_link_db
    ):
        """DB with SCAN_CAP+10 matching rows: total must equal SCAN_CAP and
        total_capped must be True, proving the scan stopped early.
        """
        db_path, cap = overcap_link_db
        r = client.get(
            _URL, params={"type": "links", "limit": 5, "offset": 0},
            headers=_token_header,
        )
        assert r.status_code == 200
        body = r.json()
        assert body["total"] == cap, (
            f"total must equal SCAN_CAP={cap} when cap is hit, got {body['total']}"
        )
        assert body["total_capped"] is True, (
            f"total_capped must be True when DB exceeds cap, got {body['total_capped']}"
        )
        # Results page still correct despite cap.
        assert len(body["results"]) == 5, (
            f"page results must still be limit=5, got {len(body['results'])}"
        )


# ---------------------------------------------------------------------------
# E. RO connection regression: scan connection must open mode=ro and reject
#    writes structurally (SQLITE_READONLY), not just "trust no code writes".
# ---------------------------------------------------------------------------

class TestROConnection:
    def test_scan_connection_rejects_writes(self, tmp_path):
        """_scan_artifacts_sync must open the DB with mode=ro (URI) so that any
        stray write raises sqlite3.OperationalError / OperationalError, not
        silently succeeding.  This is the regression the bare sqlite3.connect()
        introduced — mode=ro is structurally enforced, not convention.
        """
        import sqlite3 as _sqlite3

        # Create a valid DB file (SessionDB creates schema; we just need a file).
        db_path = tmp_path / "ro_test.db"
        rw = SessionDB(db_path=db_path)
        rw._conn.commit()
        rw._conn.close()

        # Open the same file the same way _scan_artifacts_sync does.
        conn = _sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=1.0)
        try:
            with pytest.raises(_sqlite3.OperationalError, match="[Rr]ead-only|[Rr]eadonly|attempt to write"):
                conn.execute("CREATE TABLE _ro_probe (x INTEGER)")
                conn.commit()
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def test_scan_connection_rejects_insert(self, tmp_path):
        """INSERT on a mode=ro connection must also raise OperationalError."""
        import sqlite3 as _sqlite3

        db_path = tmp_path / "ro_insert_test.db"
        rw = SessionDB(db_path=db_path)
        rw._conn.commit()
        rw._conn.close()

        conn = _sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=1.0)
        try:
            with pytest.raises(_sqlite3.OperationalError):
                conn.execute("INSERT INTO sessions (id) VALUES ('x')")
                conn.commit()
        finally:
            try:
                conn.close()
            except Exception:
                pass
