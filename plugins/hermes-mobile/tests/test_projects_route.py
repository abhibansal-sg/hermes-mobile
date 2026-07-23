"""GET /api/plugins/hermes-mobile/projects — read-only projects overview.

Mirrors the desktop's projects tab by proxying the gateway's
``_discover_repos_payload`` and reshaping to ``{id, label, root,
session_count}``. These tests assert the three acceptance contracts:

1. Auth-enforced — 401 without a session token.
2. Sane shape — every entry has exactly the four contract keys with the
   right types.
3. Junk-filtered — ~/.hermes and the bare home dir never surface, even
   when the upstream payload accidentally includes them.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"


@pytest.fixture
def api_module(monkeypatch, tmp_path):
    """Mounted plugin API module with hermetic HERMES_HOME."""
    hermes_home = tmp_path / ".hermes"
    hermes_home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))

    from hermes_cli import web_server

    if _API_MODULE_NAME not in sys.modules:
        web_server._get_dashboard_plugins(force_rescan=True)
        web_server._mount_plugin_api_routes()
    return sys.modules[_API_MODULE_NAME]


@pytest.fixture
def client(api_module):
    try:
        from starlette.testclient import TestClient
    except ImportError:
        pytest.skip("fastapi/starlette not installed")

    from hermes_cli.web_server import app, _SESSION_HEADER_NAME, _SESSION_TOKEN

    c = TestClient(app)
    c.headers[_SESSION_HEADER_NAME] = _SESSION_TOKEN
    return c


def _patch_discover(monkeypatch, repos):
    """Make the gateway proxy return *repos* without touching real state.db."""
    import tui_gateway.server as tgs

    def _fake(db, *, conn=None, backfill=True):
        return repos

    monkeypatch.setattr(tgs, "_discover_repos_payload", _fake)
    # SessionDB instantiation should never reach disk in these tests.
    monkeypatch.setattr(
        "hermes_state.SessionDB", lambda *a, **kw: object(), raising=False
    )


class _FakeSessionDB:
    """Hermetic SessionDB stand-in for the project-sessions server fallback.

    ``list_sessions_rich`` / ``session_count`` are answered from per-cwd_prefix
    tables so tests can exercise the fallback's server-owned query path without
    touching state.db. ``limit`` caps the returned rows so the authoritative-
    count contract (total > len(sessions)) is testable. Every call's kwargs are
    captured on ``list_calls`` / ``count_calls`` so desktop-aligned filtering
    (exclude cron, exclude non-listable children, ...) is assertable.
    """

    def __init__(self, *, sessions_by_prefix=None, count_by_prefix=None):
        self._sessions = sessions_by_prefix or {}
        self._counts = count_by_prefix or {}
        self.list_calls: list[dict] = []
        self.count_calls: list[dict] = []

    def list_sessions_rich(self, *, cwd_prefix=None, limit=20, **kw):
        self.list_calls.append({"cwd_prefix": cwd_prefix, "limit": limit, **kw})
        if not cwd_prefix:
            rows = []
            seen = set()
            for group in self._sessions.values():
                for row in group:
                    session_id = row.get("id")
                    if session_id not in seen:
                        seen.add(session_id)
                        rows.append(row)
            return [dict(r) for r in rows][:limit]
        rows = self._sessions.get(cwd_prefix, [])
        return [dict(r) for r in rows][:limit]

    def session_count(self, *, cwd_prefix=None, **kw):
        self.count_calls.append({"cwd_prefix": cwd_prefix, **kw})
        if not cwd_prefix:
            return 0
        return int(self._counts.get(cwd_prefix, 0))


def _patch_project_tree(monkeypatch, projects, *, session_db=None):
    """Make the project-session route consume a hydrated desktop tree.

    ``session_db`` installs the ``SessionDB`` stand-in used by the parity
    fallback (defaults to an empty ``_FakeSessionDB`` so unknown roots resolve
    to empty, not an ``AttributeError``).
    """
    import tui_gateway.server as tgs

    captured = {}

    def _fake(
        db,
        *,
        preview_limit,
        hydrate,
        session_limit,
        include_discovered,
    ):
        captured.update(
            {
                "preview_limit": preview_limit,
                "hydrate": hydrate,
                "session_limit": session_limit,
                "include_discovered": include_discovered,
            }
        )
        return {"projects": projects, "scoped_session_ids": []}, None

    monkeypatch.setattr(tgs, "_build_project_tree", _fake)
    monkeypatch.setattr(
        "hermes_state.SessionDB",
        lambda *a, **kw: session_db or _FakeSessionDB(),
        raising=False,
    )
    return captured


def test_projects_requires_auth(api_module, monkeypatch, tmp_path):
    """No session token → 401 (same belt-and-suspenders as other routes).

    Uses the ``api_module`` fixture (not a bare ``TestClient``) so the plugin
    routes are mounted against the isolated HERMES_HOME — without this, the
    module-level ``_mount_plugin_api_routes()`` at web_server import time
    runs against the real profile config and the disabled-plugin gate drops
    the route, yielding a false 404 instead of the expected 401.
    """
    from starlette.testclient import TestClient

    from hermes_cli.web_server import app

    _patch_discover(monkeypatch, [])
    resp = TestClient(app).get("/api/plugins/hermes-mobile/projects")
    assert resp.status_code == 401


def test_projects_shape_and_mapping(client, monkeypatch):
    """Each entry has exactly {id, label, root, session_count} with correct
    types, and session_count maps from the upstream ``sessions`` field."""
    _patch_discover(
        monkeypatch,
        [
            {
                "root": "/Users/alice/code/widget-app",
                "label": "widget-app",
                "sessions": 7,
                "last_active": 1700000000.0,
            },
            {
                "root": "/srv/empty-repo",
                "label": "",
                "sessions": 0,
                "last_active": 0.0,
            },
        ],
    )

    resp = client.get("/api/plugins/hermes-mobile/projects")
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert isinstance(data, list)
    assert len(data) == 2

    for entry in data:
        assert set(entry.keys()) == {"id", "label", "root", "session_count"}
        assert isinstance(entry["id"], str) and entry["id"]
        assert isinstance(entry["label"], str) and entry["label"]
        assert isinstance(entry["root"], str) and entry["root"]
        assert isinstance(entry["session_count"], int)

    # session_count maps from upstream ``sessions``.
    by_root = {e["root"]: e for e in data}
    assert by_root["/Users/alice/code/widget-app"]["session_count"] == 7
    assert by_root["/srv/empty-repo"]["session_count"] == 0
    # empty-label upstream → label falls back to basename.
    assert by_root["/srv/empty-repo"]["label"] == "empty-repo"


def test_projects_junk_filtered(client, monkeypatch, tmp_path):
    """~/.hermes subtree and bare home never surface, even if upstream leaks.

    The junk filter compares against ``HERMES_HOME`` (isolated to a temp dir
    by the conftest) and the real ``~``. We inject both as upstream repo roots
    and assert only the legitimate project survives.
    """
    import os

    hermes_home = os.environ["HERMES_HOME"]
    bare_home = os.path.expanduser("~")

    valid = str(tmp_path / "real-project")
    _patch_discover(
        monkeypatch,
        [
            {"root": hermes_home, "label": "hermes-home", "sessions": 3, "last_active": 0.0},
            {"root": bare_home, "label": "home", "sessions": 1, "last_active": 0.0},
            {"root": str(Path(hermes_home) / "skills"), "label": "skills", "sessions": 2, "last_active": 0.0},
            {
                "root": valid,
                "label": "real-project",
                "sessions": 5,
                "last_active": 0.0,
            },
        ],
    )

    resp = client.get("/api/plugins/hermes-mobile/projects")
    assert resp.status_code == 200, resp.text
    roots = {e["root"] for e in resp.json()}
    assert hermes_home not in roots
    assert bare_home not in roots
    assert str(Path(hermes_home) / "skills") not in roots
    assert valid in roots
    assert len(resp.json()) == 1


def test_projects_empty_state(client, monkeypatch):
    """No repos upstream → 200 with an empty array (not 500, not null)."""
    _patch_discover(monkeypatch, [])
    resp = client.get("/api/plugins/hermes-mobile/projects")
    assert resp.status_code == 200, resp.text
    assert resp.json() == []


def test_project_sessions_requires_auth(api_module, monkeypatch):
    """No session token -> 401 for the hydrated project sessions route."""
    from starlette.testclient import TestClient

    from hermes_cli.web_server import app

    _patch_project_tree(monkeypatch, [])
    resp = TestClient(app).get(
        "/api/plugins/hermes-mobile/project-sessions?project_id=p_widget"
    )
    assert resp.status_code == 401


def test_project_sessions_flattens_hydrated_desktop_lanes(client, monkeypatch):
    """The REST route preserves desktop repo/lane/session order."""
    captured = _patch_project_tree(
        monkeypatch,
        [
            {
                "id": "p_widget",
                "sessionCount": 3,
                "repos": [
                    {
                        "id": "/repo/widget",
                        "groups": [
                            {
                                "id": "/repo/widget::branch::main",
                                "sessions": [
                                    {"id": "main-new", "title": "Main new"},
                                    {"id": "main-old", "title": "Main old"},
                                ],
                            },
                            {
                                "id": "/repo/widget-wt-feature",
                                "sessions": [
                                    {"id": "feature", "title": "Feature"},
                                ],
                            },
                        ],
                    },
                    {
                        "id": "/repo/widget-tools",
                        "groups": [
                            {
                                "id": "/repo/widget-tools::branch::main",
                                "sessions": [],
                            }
                        ],
                    },
                ],
            }
        ],
    )

    resp = client.get(
        "/api/plugins/hermes-mobile/project-sessions",
        params={"project_id": "p_widget", "session_limit": "123"},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {
        "project_id": "p_widget",
        "sessions": [
            {"id": "main-new", "title": "Main new"},
            {"id": "main-old", "title": "Main old"},
            {"id": "feature", "title": "Feature"},
        ],
        "total": 3,
    }
    assert captured == {
        "preview_limit": 0,
        "hydrate": True,
        "session_limit": 123,
        "include_discovered": False,
    }


def test_project_sessions_folds_linked_worktrees_when_explicit_tree_undercounts(
    client, monkeypatch
):
    """Physical-device regression: the explicit project tree carried one main
    checkout row while `/projects` counted the same repo's linked worktrees.
    The detail route must prefer the larger stock-enriched repo-root fold.
    """
    repo_root = "/Volumes/MainData/Developer/products/hermes-mobile"
    worktree = "/Volumes/MainData/Developer/worktrees/hermes-mobile-feature"
    db = _FakeSessionDB(
        sessions_by_prefix={
            repo_root: [
                {
                    "id": "main",
                    "cwd": repo_root,
                    "git_repo_root": repo_root,
                    "message_count": 2,
                },
                {
                    "id": "feature",
                    "cwd": worktree,
                    "git_repo_root": repo_root,
                    "message_count": 4,
                },
            ]
        },
        count_by_prefix={repo_root: 1},
    )
    _patch_project_tree(
        monkeypatch,
        projects=[
            {
                "id": repo_root,
                "sessionCount": 1,
                "repos": [
                    {
                        "groups": [
                            {
                                "sessions": [
                                    {"id": "main", "cwd": repo_root, "message_count": 2}
                                ]
                            }
                        ]
                    }
                ],
            }
        ],
        session_db=db,
    )

    resp = client.get(
        "/api/plugins/hermes-mobile/project-sessions",
        params={"project_id": repo_root},
    )

    assert resp.status_code == 200, resp.text
    assert resp.json()["total"] == 2
    assert [row["id"] for row in resp.json()["sessions"]] == ["main", "feature"]


def test_project_sessions_unknown_project_is_empty(client, monkeypatch):
    """Unknown ids do not fall back to unrelated sessions from the tree."""
    _patch_project_tree(
        monkeypatch,
        [
            {
                "id": "p_other",
                "sessionCount": 1,
                "repos": [
                    {
                        "id": "/repo/other",
                        "groups": [
                            {
                                "id": "/repo/other::branch::main",
                                "sessions": [{"id": "do-not-leak"}],
                            }
                        ],
                    }
                ],
            }
        ],
    )

    resp = client.get(
        "/api/plugins/hermes-mobile/project-sessions",
        params={"project_id": "missing"},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"project_id": "missing", "sessions": [], "total": 0}


def test_project_sessions_fallback_for_projects_visible_root(client, monkeypatch):
    """Regression (STR-1057): a repo root visible in ``/projects`` (from
    ``_discover_repos_payload``) but absent from the
    ``include_discovered=False`` tree is still answered by the server-owned
    fallback — not returned empty/truncated.

    This is the WU1 acceptance gap: ``/projects`` returns repo-root ids, while
    ``_build_project_tree(include_discovered=False)`` can lack that root (its
    sessions owned by an explicit ``projects_db`` project under a different id,
    so the root is not a Tier-2 auto project). ``/project-sessions`` must still
    return matching server-side sessions/count for that project id.
    """
    repo_root = "/Users/alice/code/widget-app"
    db = _FakeSessionDB(
        sessions_by_prefix={
            repo_root: [
                {
                    "id": "s1",
                    "title": "Widget fix",
                    "cwd": repo_root,
                    "started_at": 1700000000.0,
                    "last_active": 1700000100.0,
                    "message_count": 4,
                    "source": "tui",
                },
            ]
        },
        count_by_prefix={repo_root: 1},
    )
    # The tree carries no project with id == repo_root (the hole).
    _patch_project_tree(monkeypatch, projects=[], session_db=db)

    resp = client.get(
        "/api/plugins/hermes-mobile/project-sessions",
        params={"project_id": repo_root},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["project_id"] == repo_root
    assert data["total"] == 1
    assert [s["id"] for s in data["sessions"]] == ["s1"]


def test_project_sessions_fallback_total_is_server_count(client, monkeypatch):
    """``total`` is the authoritative ``session_count``, not ``len(sessions)``,
    when fewer rows than the full matching set are returned.

    The fallback pairs ``list_sessions_rich`` (a capped page) with
    ``session_count`` (the uncapped total). Here the page returns 3 rows while
    the server reports 42 matching sessions — ``total`` must be 42, proving it
    is not derived from the row count.
    """
    repo_root = "/Users/alice/code/big-project"
    rows = [
        {
            "id": f"s{i}",
            "title": f"Session {i}",
            "cwd": repo_root,
            "started_at": 1700000000.0 + i,
            "last_active": 1700000100.0 + i,
            "message_count": 2,
            "source": "tui",
        }
        for i in range(3)
    ]
    db = _FakeSessionDB(
        sessions_by_prefix={repo_root: rows},
        count_by_prefix={repo_root: 42},
    )
    _patch_project_tree(monkeypatch, projects=[], session_db=db)

    resp = client.get(
        "/api/plugins/hermes-mobile/project-sessions",
        params={"project_id": repo_root, "session_limit": "3"},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert len(data["sessions"]) == 3
    assert data["total"] == 42


def test_project_sessions_fallback_mirrors_desktop_filtering(client, monkeypatch):
    """The server fallback applies the same desktop-lane filtering as
    ``_project_tree_inputs``: exclude cron, exclude non-listable children,
    require non-empty human sessions, order by recent activity — and pairs
    ``list_sessions_rich`` with ``session_count(exclude_children=True)`` so the
    total is authoritative.
    """
    repo_root = "/Users/alice/code/widget-app"
    db = _FakeSessionDB(
        sessions_by_prefix={
            repo_root: [
                {
                    "id": "s1",
                    "title": "Widget fix",
                    "cwd": repo_root,
                    "source": "tui",
                    "message_count": 4,
                }
            ]
        },
        count_by_prefix={repo_root: 1},
    )
    _patch_project_tree(monkeypatch, projects=[], session_db=db)

    resp = client.get(
        "/api/plugins/hermes-mobile/project-sessions",
        params={"project_id": repo_root},
    )
    assert resp.status_code == 200, resp.text

    assert db.list_calls and db.count_calls
    lc = next(call for call in db.list_calls if call["cwd_prefix"] == repo_root)
    assert lc["cwd_prefix"] == repo_root
    assert lc["exclude_sources"] == ["cron"]
    assert lc["include_children"] is False
    assert lc["min_message_count"] == 1
    assert lc["order_by_last_active"] is True
    fold_call = next(call for call in db.list_calls if call["cwd_prefix"] is None)
    assert fold_call["exclude_sources"] == ["cron"]
    assert fold_call["include_children"] is False
    assert fold_call["min_message_count"] == 1
    assert fold_call["order_by_last_active"] is True
    cc = db.count_calls[-1]
    assert cc["cwd_prefix"] == repo_root
    assert cc["exclude_children"] is True
    assert cc["exclude_sources"] == ["cron"]


# ---------------------------------------------------------------------------
# POST /projects — create a project (name + root path) from the iOS tab.
#
# The route validates its input and delegates to the stock
# ``hermes_cli.projects_db.create_project`` (imported + called; ZERO core
# patch). These tests pin: auth, input validation, the file-not-a-dir reject,
# and a real create happy-path against an isolated temp projects DB.
# ---------------------------------------------------------------------------


@pytest.fixture
def temp_projects_db(monkeypatch, tmp_path):
    """Point ``projects_db`` at an isolated temp DB for both the route's create
    and the test's verification, so the happy-path never touches real state."""
    from hermes_cli import projects_db as pdb

    db_file = tmp_path / "projects.db"
    monkeypatch.setattr(pdb, "projects_db_path", lambda: db_file)
    # Drop any per-path init memo so the fresh temp path re-applies the schema.
    monkeypatch.setattr(pdb, "_INITIALIZED_PATHS", set())
    return db_file


def test_create_project_requires_auth(api_module):
    """No session token -> 401 (belt-and-suspenders, like the read routes)."""
    from starlette.testclient import TestClient

    from hermes_cli.web_server import app

    resp = TestClient(app).post(
        "/api/plugins/hermes-mobile/projects",
        json={"name": "X", "root": "/tmp/x"},
    )
    assert resp.status_code == 401


def test_create_project_rejects_empty_name(client, temp_projects_db):
    resp = client.post(
        "/api/plugins/hermes-mobile/projects",
        json={"name": "   ", "root": "/tmp/x"},
    )
    assert resp.status_code == 400
    assert "name" in resp.json()["detail"].lower()


def test_create_project_rejects_empty_root(client, temp_projects_db):
    resp = client.post(
        "/api/plugins/hermes-mobile/projects",
        json={"name": "X", "root": "  "},
    )
    assert resp.status_code == 400
    assert "root" in resp.json()["detail"].lower()


def test_create_project_rejects_file_root(client, temp_projects_db, tmp_path):
    """A root that exists but is a FILE (not a directory) is rejected."""
    file_path = tmp_path / "not-a-dir.txt"
    file_path.write_text("hi")

    resp = client.post(
        "/api/plugins/hermes-mobile/projects",
        json={"name": "X", "root": str(file_path)},
    )
    assert resp.status_code == 400
    assert "director" in resp.json()["detail"].lower()


def test_create_project_happy_path_persists_and_returns_contract(
    client, temp_projects_db, tmp_path
):
    """A valid create returns the ``{id, label, root, session_count}`` contract
    and actually writes a row via the stock ``create_project``."""
    from hermes_cli import projects_db as pdb

    root = tmp_path / "code" / "widget-app"
    root.mkdir(parents=True)

    resp = client.post(
        "/api/plugins/hermes-mobile/projects",
        json={"name": "Widget App", "root": str(root)},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert set(body.keys()) == {"id", "label", "root", "session_count"}
    assert body["label"] == "Widget App"
    assert body["root"] == str(root)
    assert body["id"] == str(root)
    assert body["session_count"] == 0

    # The stock backend actually recorded it (verify against the same temp DB).
    with pdb.connect_closing() as conn:
        names = [p.name for p in pdb.list_projects(conn)]
    assert "Widget App" in names


def test_create_project_accepts_nonexistent_root(client, temp_projects_db, tmp_path):
    """A not-yet-created path is allowed (``create_project`` just records it)."""
    root = tmp_path / "future" / "repo"  # deliberately absent on disk

    resp = client.post(
        "/api/plugins/hermes-mobile/projects",
        json={"name": "Future", "root": str(root)},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["root"] == str(root)


# ---------------------------------------------------------------------------
# GET /projects ∪ projects_db — the create/overview round-trip (wave25-b2).
#
# ``_discover_repos_payload`` derives roots from session cwds ∪ filesystem git
# scan; neither sees a brand-new zero-session project. The overview must UNION
# ``projects_db.list_projects`` so a just-created project is visible on Back.
# ---------------------------------------------------------------------------


def test_overview_includes_zero_session_projects_db_project(
    client, monkeypatch, temp_projects_db, tmp_path
):
    """A projects_db project with no sessions and no filesystem scan hit still
    surfaces in the overview, keyed by its normalized ``primary_path``."""
    from hermes_cli import projects_db as pdb

    _patch_discover(monkeypatch, [])  # nothing session/scan-derived
    root = tmp_path / "code" / "fresh-app"
    root.mkdir(parents=True)
    with pdb.connect_closing() as conn:
        pdb.create_project(conn, name="Fresh App", primary_path=str(root))

    resp = client.get("/api/plugins/hermes-mobile/projects")
    assert resp.status_code == 200, resp.text
    data = resp.json()
    by_root = {e["root"]: e for e in data}
    assert str(root) in by_root, data
    entry = by_root[str(root)]
    assert set(entry.keys()) == {"id", "label", "root", "session_count"}
    assert entry["id"] == str(root)  # same id POST /projects returns
    assert entry["label"] == "Fresh App"
    assert entry["session_count"] == 0


def test_create_then_overview_round_trip(
    client, monkeypatch, temp_projects_db, tmp_path
):
    """End-to-end: POST /projects then GET /projects surfaces the new project
    (the exact bug — created project absent from the overview after Back)."""
    _patch_discover(monkeypatch, [])
    root = tmp_path / "future" / "repo"  # not-yet-existing folder

    created = client.post(
        "/api/plugins/hermes-mobile/projects",
        json={"name": "Round Trip", "root": str(root)},
    )
    assert created.status_code == 200, created.text
    created_id = created.json()["id"]

    overview = client.get("/api/plugins/hermes-mobile/projects")
    assert overview.status_code == 200, overview.text
    ids = {e["id"] for e in overview.json()}
    assert created_id in ids, overview.json()


def test_overview_dedupes_projects_db_root_against_discovered(
    client, monkeypatch, temp_projects_db, tmp_path
):
    """When a projects_db project's root is ALSO a discovered repo, it appears
    once, and the discovered entry (which carries the real session_count) wins
    — the union must not duplicate the root."""
    from hermes_cli import projects_db as pdb

    root = tmp_path / "code" / "widget-app"
    root.mkdir(parents=True)
    _patch_discover(
        monkeypatch,
        [{"root": str(root), "label": "widget-app", "sessions": 5, "last_active": 0.0}],
    )
    with pdb.connect_closing() as conn:
        pdb.create_project(conn, name="Widget App", primary_path=str(root))

    resp = client.get("/api/plugins/hermes-mobile/projects")
    assert resp.status_code == 200, resp.text
    matches = [e for e in resp.json() if e["root"] == str(root)]
    assert len(matches) == 1, matches
    assert matches[0]["session_count"] == 5  # discovered entry wins


def test_overview_skips_archived_projects_db_project(
    client, monkeypatch, temp_projects_db, tmp_path
):
    """Archived projects_db projects are excluded (list_projects default)."""
    from hermes_cli import projects_db as pdb

    _patch_discover(monkeypatch, [])
    root = tmp_path / "code" / "gone"
    root.mkdir(parents=True)
    with pdb.connect_closing() as conn:
        pid = pdb.create_project(conn, name="Gone", primary_path=str(root))
        pdb.archive_project(conn, pid)

    resp = client.get("/api/plugins/hermes-mobile/projects")
    assert resp.status_code == 200, resp.text
    assert str(root) not in {e["root"] for e in resp.json()}
