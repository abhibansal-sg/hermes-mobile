"""F4A-S — REST GET .../fs/list + GET .../fs/read (hermes-mobile plugin API).

Session-scoped, sandboxed filesystem browse endpoints backing the hermes-mobile
iOS file browser + text viewer. GREENFIELD: no prior surface lists a directory
or returns a file's bytes under a session cwd. Auth mirrors ``.../upload`` (the
standard dashboard session token). Tests run entirely in-process via FastAPI
TestClient — no network. The session cwd ROOT is registered in the gateway's
``_sessions`` map (the same map ``.../approvals/respond`` reads), pointed at a
``tmp_path`` sandbox so traversal/symlink-escape attempts can be proven rejected.

ABH-88 de-patch (W1): the routes moved verbatim from ``hermes_cli/web_server.py``
into ``plugins/hermes-mobile/dashboard/api.py``, auto-mounted at
``/api/plugins/hermes-mobile/`` when web_server is imported. The sandbox helpers
(``FsSandboxError``, ``_resolve_under_session_cwd``, ``_MAX_FS_*``) live in that
api module now — monkeypatches/asserts target it via ``_api()`` below.
"""

from __future__ import annotations

import os
import sys

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from tui_gateway import server as gateway

pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")


def _api():
    """The mounted plugin api module, resolved LIVE per call.

    ``web_server._mount_plugin_api_routes()`` registers it in ``sys.modules``
    at web_server import. Resolved lazily (not captured at import time) so a
    sibling test's ``importlib.reload(web_server)`` — which re-mounts and
    re-registers the module — can't leave us holding a stale reference.
    """
    return sys.modules["hermes_dashboard_plugin_hermes-mobile"]

@pytest.fixture
def _token_header():
    """The dashboard session-token header, resolved LIVE per test.

    A sibling in the same xdist group (``test_web_server`` ->
    ``test_honors_injected_token``) calls ``importlib.reload(web_server)``,
    which regenerates the module-global ``_SESSION_TOKEN``. Capturing the
    token once at import time would go stale and 401 every request, so we
    read it at call time to stay order-independent.
    """
    return {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}


@pytest.fixture
def loopback_client():
    prev_host = getattr(web_server.app.state, "bound_host", None)
    prev_port = getattr(web_server.app.state, "bound_port", None)
    prev_required = getattr(web_server.app.state, "auth_required", None)
    web_server.app.state.bound_host = "127.0.0.1"
    web_server.app.state.bound_port = 8080
    web_server.app.state.auth_required = False
    client = TestClient(web_server.app, base_url="http://127.0.0.1:8080")
    yield client
    web_server.app.state.bound_host = prev_host
    web_server.app.state.bound_port = prev_port
    web_server.app.state.auth_required = prev_required


@pytest.fixture
def session_cwd(tmp_path):
    """Register a runtime session whose cwd ROOT is an isolated tmp tree.

    Lays down a small, deterministic tree:
        <root>/
          alpha.txt           "hello alpha\n"
          beta.bin            <non-UTF-8 bytes>
          .hidden             "dot\n"
          zsub/               (dir)
            nested.txt        "nested\n"
        <outside>/secret.txt  (sibling of root, for symlink-escape tests)
    """
    root = tmp_path / "workspace"
    root.mkdir()
    (root / "alpha.txt").write_text("hello alpha\n", encoding="utf-8")
    (root / "beta.bin").write_bytes(b"\x89PNG\r\n\x1a\n\x00\xff\xfe\xfd")
    (root / ".hidden").write_text("dot\n", encoding="utf-8")
    sub = root / "zsub"
    sub.mkdir()
    (sub / "nested.txt").write_text("nested\n", encoding="utf-8")

    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("TOP SECRET\n", encoding="utf-8")

    sid = "fs-sid-1"
    gateway._sessions[sid] = {
        "session_key": "fs-key-1",
        "cwd": str(root),
    }
    try:
        yield sid, root, outside
    finally:
        gateway._sessions.pop(sid, None)


# ---------------------------------------------------------------------------
# Auth — 401 on bad/absent token (both endpoints)
# ---------------------------------------------------------------------------

def test_list_requires_token(loopback_client, session_cwd):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(f"/api/plugins/hermes-mobile/fs/list?session_id={sid}")
    assert r.status_code == 401


def test_list_bad_token(loopback_client, session_cwd):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/list?session_id={sid}",
        headers={"X-Hermes-Session-Token": "wrong-token"},
    )
    assert r.status_code == 401


def test_read_requires_token(loopback_client, session_cwd):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=alpha.txt")
    assert r.status_code == 401


# ---------------------------------------------------------------------------
# /api/fs/list — required-param + happy paths
# ---------------------------------------------------------------------------

def test_list_missing_session_id_400(loopback_client, _token_header):
    r = loopback_client.get("/api/plugins/hermes-mobile/fs/list", headers=_token_header)
    assert r.status_code == 400
    assert r.json() == {"error": "session_id required"}


def test_list_root_sorted_dirs_first(loopback_client, session_cwd, _token_header):
    sid, root, _outside = session_cwd
    r = loopback_client.get(f"/api/plugins/hermes-mobile/fs/list?session_id={sid}", headers=_token_header)
    assert r.status_code == 200
    body = r.json()
    assert body["root"] == os.path.realpath(str(root))
    assert body["path"] == ""
    names = [e["name"] for e in body["entries"]]
    # zsub (dir) sorts before files despite the 'z' name — dirs-first.
    assert names[0] == "zsub"
    assert body["entries"][0]["is_dir"] is True
    # Dotfiles are INCLUDED.
    assert ".hidden" in names
    assert {"alpha.txt", "beta.bin", ".hidden"} <= set(names)
    # File entries carry size + modified; dirs report size 0.
    alpha = next(e for e in body["entries"] if e["name"] == "alpha.txt")
    assert alpha["is_dir"] is False
    assert alpha["size"] == len("hello alpha\n")
    assert isinstance(alpha["modified"], float)
    zsub = next(e for e in body["entries"] if e["name"] == "zsub")
    assert zsub["size"] == 0
    assert "truncated" not in body


def test_list_subdir_via_path(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/list?session_id={sid}&path=zsub", headers=_token_header
    )
    assert r.status_code == 200
    body = r.json()
    assert body["path"] == "zsub"
    assert [e["name"] for e in body["entries"]] == ["nested.txt"]


def test_list_truncates_at_cap(loopback_client, session_cwd, monkeypatch, _token_header):
    sid, root, _outside = session_cwd
    big = root / "many"
    big.mkdir()
    for i in range(5):
        (big / f"f{i}.txt").write_text("x", encoding="utf-8")
    monkeypatch.setattr(_api(), "_MAX_FS_LIST_ENTRIES", 3)
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/list?session_id={sid}&path=many", headers=_token_header
    )
    assert r.status_code == 200
    body = r.json()
    assert len(body["entries"]) == 3
    assert body["truncated"] is True


# ---------------------------------------------------------------------------
# /api/fs/list — error mapping
# ---------------------------------------------------------------------------

def test_list_path_is_file_404(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/list?session_id={sid}&path=alpha.txt", headers=_token_header
    )
    assert r.status_code == 404
    assert r.json() == {"error": "not a directory"}


def test_list_missing_path_404(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/list?session_id={sid}&path=does-not-exist", headers=_token_header
    )
    assert r.status_code == 404
    assert r.json() == {"error": "not a directory"}


def test_list_unknown_sid_404_unknown_session(loopback_client, _token_header):
    # R1-fix finding 2: an unknown/stale sid 404s as "unknown session" — it does
    # NOT fall back to the dashboard's own cwd (which would leak the workspace to
    # any client presenting a bogus sid). The 404 fires even for the ROOT listing
    # (no sub-path needed), unlike the old env/cwd-fallback behaviour.
    r = loopback_client.get(
        "/api/plugins/hermes-mobile/fs/list?session_id=ghost",
        headers=_token_header,
    )
    assert r.status_code == 404
    assert r.json() == {"error": "unknown session"}


def test_read_unknown_sid_404_unknown_session(loopback_client, _token_header):
    # The read endpoint shares the same resolver, so a bogus sid 404s there too.
    r = loopback_client.get(
        "/api/plugins/hermes-mobile/fs/read?session_id=ghost&path=anything.txt",
        headers=_token_header,
    )
    assert r.status_code == 404
    assert r.json() == {"error": "unknown session"}


# ---------------------------------------------------------------------------
# Sandbox / traversal — 403 (the security-critical cases)
# ---------------------------------------------------------------------------

def test_list_dotdot_escape_403(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/list?session_id={sid}&path=../outside", headers=_token_header
    )
    assert r.status_code == 403
    assert r.json() == {"error": "path escapes session root"}


def test_list_deep_dotdot_escape_403(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/list?session_id={sid}&path=../../../../../../etc",
        headers=_token_header,
    )
    assert r.status_code == 403


def test_read_absolute_path_refused(loopback_client, session_cwd, _token_header):
    """Absolute paths are NOT honoured as roots (unlike complete.path).

    ``/etc/passwd`` is joined onto root → ``<root>/etc/passwd`` which does not
    exist → 404. The endpoint must never return /etc/passwd's bytes.
    """
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=/etc/passwd", headers=_token_header
    )
    assert r.status_code == 404
    assert r.json() == {"error": "not a file"}


def test_read_symlink_escape_403(loopback_client, session_cwd, _token_header):
    """A symlink inside the root pointing OUT of the tree is rejected.

    realpath resolves the link target before the prefix check, so reading
    through it must 403 rather than leak the outside file.
    """
    sid, root, outside = session_cwd
    link = root / "escape_link"
    try:
        os.symlink(str(outside / "secret.txt"), str(link))
    except (OSError, NotImplementedError):
        pytest.skip("symlinks unsupported on this platform")
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=escape_link", headers=_token_header
    )
    assert r.status_code == 403
    assert r.json() == {"error": "path escapes session root"}


def test_list_symlink_dir_escape_403(loopback_client, session_cwd, _token_header):
    sid, root, outside = session_cwd
    link = root / "escape_dir"
    try:
        os.symlink(str(outside), str(link), target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks unsupported on this platform")
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/list?session_id={sid}&path=escape_dir", headers=_token_header
    )
    assert r.status_code == 403


def test_list_null_byte_path_400(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/list?session_id={sid}&path=%00", headers=_token_header
    )
    assert r.status_code == 400
    assert r.json() == {"error": "invalid path"}


def test_read_null_byte_path_400(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=%00", headers=_token_header
    )
    assert r.status_code == 400
    assert r.json() == {"error": "invalid path"}


def test_list_symlink_child_escape_hides_target_metadata(
    loopback_client, session_cwd, _token_header
):
    sid, root, outside = session_cwd
    link = root / "escape_dir_child"
    try:
        os.symlink(str(outside), str(link), target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks unsupported on this platform")

    r = loopback_client.get(f"/api/plugins/hermes-mobile/fs/list?session_id={sid}", headers=_token_header)
    assert r.status_code == 200
    entry = next(e for e in r.json()["entries"] if e["name"] == "escape_dir_child")
    assert entry == {
        "name": "escape_dir_child",
        "is_dir": False,
        "size": 0,
        "modified": 0.0,
    }


# ---------------------------------------------------------------------------
# /api/fs/read — happy paths + caps + binary policy
# ---------------------------------------------------------------------------

def test_read_text_file(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=alpha.txt", headers=_token_header
    )
    assert r.status_code == 200
    body = r.json()
    assert body["encoding"] == "utf-8"
    assert body["content"] == "hello alpha\n"
    assert body["size"] == len("hello alpha\n")
    assert body["truncated"] is False
    assert body["path"] == "alpha.txt"


def test_read_text_in_subdir(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=zsub/nested.txt", headers=_token_header
    )
    assert r.status_code == 200
    assert r.json()["content"] == "nested\n"


def test_read_binary_file(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=beta.bin", headers=_token_header
    )
    assert r.status_code == 200
    body = r.json()
    assert body["encoding"] == "binary"
    assert body["content"] is None
    assert body["size"] > 0


def test_read_missing_session_id_400(loopback_client, _token_header):
    r = loopback_client.get("/api/plugins/hermes-mobile/fs/read?path=alpha.txt", headers=_token_header)
    assert r.status_code == 400
    assert r.json() == {"error": "session_id required"}


def test_read_missing_path_400(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}", headers=_token_header
    )
    assert r.status_code == 400


def test_read_dir_is_404(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=zsub", headers=_token_header
    )
    assert r.status_code == 404
    assert r.json() == {"error": "not a file"}


def test_read_missing_file_404(loopback_client, session_cwd, _token_header):
    sid, _root, _outside = session_cwd
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=nope.txt", headers=_token_header
    )
    assert r.status_code == 404


def test_read_over_cap_binary_413(loopback_client, session_cwd, monkeypatch, _token_header):
    sid, root, _outside = session_cwd
    monkeypatch.setattr(_api(), "_MAX_FS_READ_BYTES", 16)
    big = root / "big.bin"
    big.write_bytes(b"\xff\xfe" * 64)  # 128 bytes, non-UTF-8
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=big.bin", headers=_token_header
    )
    assert r.status_code == 413
    body = r.json()
    assert body["error"] == "file too large"
    assert body["size"] == 128


def test_read_over_cap_text_truncates_not_413(loopback_client, session_cwd, monkeypatch, _token_header):
    """A large-but-text file is truncated + flagged, NOT 413'd (contract)."""
    sid, root, _outside = session_cwd
    monkeypatch.setattr(_api(), "_MAX_FS_READ_BYTES", 10)
    big = root / "big.txt"
    big.write_text("A" * 100, encoding="utf-8")
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=big.txt", headers=_token_header
    )
    assert r.status_code == 200
    body = r.json()
    assert body["encoding"] == "utf-8"
    assert body["truncated"] is True
    assert body["size"] == 100
    assert body["content"] == "A" * 10  # truncated to the cap


def test_read_over_cap_text_split_multibyte_truncates(loopback_client, session_cwd, monkeypatch, _token_header):
    """A multibyte codepoint sliced at the cap boundary must not misclassify
    a text file as binary/over-cap."""
    sid, root, _outside = session_cwd
    monkeypatch.setattr(_api(), "_MAX_FS_READ_BYTES", 5)
    big = root / "uni.txt"
    # 'é' is 2 bytes in UTF-8; placing one at the boundary forces a split.
    big.write_text("abcdé" * 10, encoding="utf-8")
    r = loopback_client.get(
        f"/api/plugins/hermes-mobile/fs/read?session_id={sid}&path=uni.txt", headers=_token_header
    )
    assert r.status_code == 200
    body = r.json()
    assert body["encoding"] == "utf-8"
    assert body["truncated"] is True
    # Trailing partial 'é' dropped; clean prefix returned.
    assert body["content"] == "abcd"


# ---------------------------------------------------------------------------
# Shared resolver — unit coverage of the sandbox seam
# ---------------------------------------------------------------------------

def test_resolver_rejects_escape(session_cwd):
    sid, _root, _outside = session_cwd
    with pytest.raises(_api().FsSandboxError) as exc:
        _api()._resolve_under_session_cwd(sid, "../outside")
    assert exc.value.status_code == 403
    assert exc.value.error == "path escapes session root"


def test_resolver_allows_in_tree(session_cwd):
    sid, root, _outside = session_cwd
    resolved_root, abspath = _api()._resolve_under_session_cwd(sid, "zsub")
    assert resolved_root == os.path.realpath(str(root))
    assert abspath == os.path.join(os.path.realpath(str(root)), "zsub")
