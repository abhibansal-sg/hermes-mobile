"""Memory write-review REST surface under /api/plugins/hermes-mobile/memory/.

ABH-303 / STR-538: a structured, authenticated JSON surface so iOS reviews
staged memory writes without parsing the ``/memory`` slash-command text.
Mirrors the gateway ``/memory`` pending/approve/reject/approval code path
(``gateway/slash_commands.py:_handle_memory_command`` +
``hermes_cli.write_approval_commands.handle_pending_subcommand``) but returns
JSON and never exposes skill pending writes.

Covered:

* ``GET  .../memory/pending``  — auth, device approve-scope, pending list
  shape, missing-dir empty-not-500, skill writes never surfaced.
* ``POST .../memory/approve``  — single apply to MEMORY.md + USER.md,
  pending removal on success, ``all`` apply, unknown id -> 404, missing
  id -> 400, path-traversal/``..`` id -> 400 (never reaches write_approval).
* ``POST .../memory/reject``   — single discard without applying, ``all``
  discard, unknown id -> 404, missing id -> 400, path-traversal/``..`` id
  -> 400 and a staged SKILL pending record is never deleted through it.
* ``PUT  .../memory/approval`` — toggle persists ``memory.write_approval``
  and is reflected by ``write_approval_enabled`` + the pending response.

All in-process via TestClient + the autouse hermetic HERMES_HOME fixture so
no write ever touches the real ``~/.hermes``.
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from tools import write_approval as wa

from tests.plugins.hermes_mobile.conftest import load_plugin_module

device_tokens = load_plugin_module("device_tokens")

# Mutates web_server.app.state — share the dashboard app-state xdist group so
# it doesn't race other app-state files (per the repo convention).
pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

_PREFIX = "/api/plugins/hermes-mobile"
_MEM_PREFIX = f"{_PREFIX}/memory"

_SHARED_HEADER = {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}


@pytest.fixture
def home(monkeypatch, tmp_path):
    """Pin HERMES_HOME to a throwaway dir + reset the device-token registry.

    The autouse ``_hermetic_environment`` already redirects HERMES_HOME, but
    this fixture re-pins it to a per-test tmp_path (matching the approval-audit
    test convention) so config.yaml + pending writes never escape the sandbox.
    """
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    device_tokens._reset_for_tests()
    yield tmp_path
    device_tokens._reset_for_tests()


@pytest.fixture
def client():
    prev_host = getattr(web_server.app.state, "bound_host", None)
    prev_required = getattr(web_server.app.state, "auth_required", None)
    web_server.app.state.bound_host = "127.0.0.1"
    web_server.app.state.bound_port = 8080
    web_server.app.state.auth_required = False
    c = TestClient(web_server.app, base_url="http://127.0.0.1:8080")
    yield c
    web_server.app.state.bound_host = prev_host
    web_server.app.state.auth_required = prev_required


def _stage_memory(
    *, action: str = "add",
    target: str = "memory",
    content: str = "prefers concise answers",
    old_text: str | None = None,
    summary: str = "add to memory",
    origin: str = "foreground",
) -> dict:
    """Stage one memory write and return the pending record."""
    payload: dict = {"action": action, "target": target, "content": content}
    if old_text is not None:
        payload["old_text"] = old_text
    return wa.stage_write(wa.MEMORY, payload, summary=summary, origin=origin)


def _memory_md_text(home) -> str:
    return (home / "memories" / "MEMORY.md").read_text(encoding="utf-8")


def _user_md_text(home) -> str:
    return (home / "memories" / "USER.md").read_text(encoding="utf-8")


# ===========================================================================
# GET /memory/pending — auth, scope, shape, empty-on-missing, no skills
# ===========================================================================


def test_pending_requires_token(client, home):
    assert client.get(f"{_MEM_PREFIX}/pending").status_code == 401


def test_pending_device_token_without_approve_scope_403(
    client, home, wired_token_auth
):
    issued = device_tokens.issue(device_name="Chat Only")
    registry_path = home / "device_tokens.json"
    registry = json.loads(registry_path.read_text())
    registry[issued["device_id"]]["scopes"] = ["chat"]
    registry_path.write_text(json.dumps(registry), encoding="utf-8")

    r = client.get(
        f"{_MEM_PREFIX}/pending",
        headers={"X-Hermes-Session-Token": issued["token"]},
    )
    assert r.status_code == 403


def test_pending_lists_staged_write(client, home):
    rec = _stage_memory(content="likes dark mode", summary="add to user profile")
    r = client.get(f"{_MEM_PREFIX}/pending", headers=_SHARED_HEADER)
    assert r.status_code == 200
    body = r.json()
    assert body["approval_enabled"] is False
    pending = body["pending"]
    assert len(pending) == 1
    item = pending[0]
    assert item["id"] == rec["id"]
    assert item["summary"] == "add to user profile"
    assert item["origin"] == "foreground"
    assert item["created_at"] == rec["created_at"]
    assert item["action"] == "add"
    assert item["target"] == "memory"
    assert item["content"] == "likes dark mode"
    assert item["old_text"] is None
    assert item["operations"] is None


def test_pending_missing_dir_is_empty_not_500(client, home):
    # No pending writes staged — the pending dir does not even exist yet.
    r = client.get(f"{_MEM_PREFIX}/pending", headers=_SHARED_HEADER)
    assert r.status_code == 200
    assert r.json() == {"approval_enabled": False, "pending": []}


def test_pending_never_exposes_skill_writes(client, home):
    # A staged SKILL write must never surface on the memory review endpoint.
    wa.stage_write(
        wa.SKILLS,
        {"action": "create", "name": "s", "content": "..."},
        summary="create skill s",
        origin="foreground",
    )
    _stage_memory(content="a memory entry")
    r = client.get(f"{_MEM_PREFIX}/pending", headers=_SHARED_HEADER)
    assert r.status_code == 200
    pending = r.json()["pending"]
    assert len(pending) == 1
    assert pending[0]["target"] == "memory"


# ===========================================================================
# POST /memory/approve — apply through the real store path
# ===========================================================================


def test_approve_single_applies_to_memory_and_removes_pending(client, home):
    rec = _stage_memory(content="project uses tabs not spaces")
    r = client.post(
        f"{_MEM_PREFIX}/approve", json={"id": rec["id"]}, headers=_SHARED_HEADER
    )
    assert r.status_code == 200
    body = r.json()
    assert body["approved"] == 1
    assert body["failed"] == []
    assert body["pending_count"] == 0
    # The staged write landed in MEMORY.md ...
    assert "project uses tabs not spaces" in _memory_md_text(home)
    # ... and was removed from the pending store.
    assert wa.get_pending(wa.MEMORY, rec["id"]) is None


def test_approve_single_applies_to_user_md(client, home):
    rec = _stage_memory(
        target="user", content="name is Abhi", summary="add to user profile"
    )
    r = client.post(
        f"{_MEM_PREFIX}/approve", json={"id": rec["id"]}, headers=_SHARED_HEADER
    )
    assert r.status_code == 200
    assert r.json()["approved"] == 1
    assert "name is Abhi" in _user_md_text(home)
    assert wa.pending_count(wa.MEMORY) == 0


def test_approve_unknown_id_404(client, home):
    r = client.post(
        f"{_MEM_PREFIX}/approve", json={"id": "deadbeef"}, headers=_SHARED_HEADER
    )
    assert r.status_code == 404


def test_approve_missing_id_400(client, home):
    r = client.post(
        f"{_MEM_PREFIX}/approve", json={"id": ""}, headers=_SHARED_HEADER
    )
    assert r.status_code == 400
    r2 = client.post(f"{_MEM_PREFIX}/approve", json={}, headers=_SHARED_HEADER)
    assert r2.status_code == 400


def test_approve_all_applies_every_staged_write(client, home):
    _stage_memory(content="entry one")
    _stage_memory(content="entry two")
    r = client.post(
        f"{_MEM_PREFIX}/approve", json={"id": "all"}, headers=_SHARED_HEADER
    )
    assert r.status_code == 200
    body = r.json()
    assert body["approved"] == 2
    assert body["failed"] == []
    assert body["pending_count"] == 0
    md = _memory_md_text(home)
    assert "entry one" in md
    assert "entry two" in md


def test_approve_all_with_no_pending_is_zero_not_404(client, home):
    r = client.post(
        f"{_MEM_PREFIX}/approve", json={"id": "all"}, headers=_SHARED_HEADER
    )
    assert r.status_code == 200
    assert r.json() == {"approved": 0, "failed": [], "pending_count": 0}


def test_approve_failed_write_reported_not_applied(client, home):
    # A 'remove' with no matching entry fails inside apply_memory_pending; the
    # record must NOT be discarded and the failure must be reported.
    rec = wa.stage_write(
        wa.MEMORY,
        {"action": "remove", "target": "memory", "old_text": "never existed"},
        summary="remove missing",
        origin="foreground",
    )
    r = client.post(
        f"{_MEM_PREFIX}/approve", json={"id": rec["id"]}, headers=_SHARED_HEADER
    )
    assert r.status_code == 200
    body = r.json()
    assert body["approved"] == 0
    assert len(body["failed"]) == 1
    assert body["failed"][0]["id"] == rec["id"]
    # The failed record stays pending (only successes are discarded).
    assert body["pending_count"] == 1


# ===========================================================================
# POST /memory/reject — discard without applying
# ===========================================================================


def test_reject_single_removes_pending_without_applying(client, home):
    rec = _stage_memory(content="should not be saved")
    r = client.post(
        f"{_MEM_PREFIX}/reject", json={"id": rec["id"]}, headers=_SHARED_HEADER
    )
    assert r.status_code == 200
    body = r.json()
    assert body["rejected"] == 1
    assert body["pending_count"] == 0
    # Nothing was written to MEMORY.md ...
    assert not (home / "memories" / "MEMORY.md").exists()
    # ... and the record is gone.
    assert wa.get_pending(wa.MEMORY, rec["id"]) is None


def test_reject_all_discards_every_staged_write(client, home):
    _stage_memory(content="entry one")
    _stage_memory(content="entry two")
    r = client.post(
        f"{_MEM_PREFIX}/reject", json={"id": "all"}, headers=_SHARED_HEADER
    )
    assert r.status_code == 200
    body = r.json()
    assert body["rejected"] == 2
    assert body["pending_count"] == 0
    assert not (home / "memories" / "MEMORY.md").exists()


def test_reject_unknown_id_404(client, home):
    r = client.post(
        f"{_MEM_PREFIX}/reject", json={"id": "deadbeef"}, headers=_SHARED_HEADER
    )
    assert r.status_code == 404


def test_reject_missing_id_400(client, home):
    assert client.post(
        f"{_MEM_PREFIX}/reject", json={"id": ""}, headers=_SHARED_HEADER
    ).status_code == 400


# ===========================================================================
# Path-traversal hardening — ids are validated at the REST boundary.
# Regression for the STR-538 review finding: ``write_approval`` builds a
# pending file path from the caller-supplied id, so a value like
# ``../skills/<id>`` would traverse out of ``pending/memory`` into a sibling
# subsystem. The boundary must 400 before any filesystem access and never
# touch a staged SKILL pending record.
# ===========================================================================


def test_reject_skill_traversal_id_is_400_and_keeps_skill_pending(client, home):
    mem = _stage_memory(content="a real memory entry")
    skill = wa.stage_write(
        wa.SKILLS,
        {"action": "create", "name": "s", "content": "skill body"},
        summary="create skill s",
        origin="foreground",
    )
    traversal = f"../skills/{skill['id']}"

    r = client.post(
        f"{_MEM_PREFIX}/reject", json={"id": traversal}, headers=_SHARED_HEADER
    )
    assert r.status_code == 400
    # The traversal never reached write_approval: both records are intact.
    assert wa.get_pending(wa.SKILLS, skill["id"]) is not None
    assert wa.get_pending(wa.MEMORY, mem["id"]) is not None
    assert wa.pending_count(wa.SKILLS) == 1
    assert wa.pending_count(wa.MEMORY) == 1


def test_approve_skill_traversal_id_is_400_and_keeps_skill_pending(client, home):
    mem = _stage_memory(content="a real memory entry")
    skill = wa.stage_write(
        wa.SKILLS,
        {"action": "create", "name": "s", "content": "skill body"},
        summary="create skill s",
        origin="foreground",
    )
    traversal = f"../skills/{skill['id']}"

    r = client.post(
        f"{_MEM_PREFIX}/approve", json={"id": traversal}, headers=_SHARED_HEADER
    )
    assert r.status_code == 400
    assert wa.get_pending(wa.SKILLS, skill["id"]) is not None
    assert wa.get_pending(wa.MEMORY, mem["id"]) is not None
    assert wa.pending_count(wa.SKILLS) == 1
    assert wa.pending_count(wa.MEMORY) == 1


@pytest.mark.parametrize(
    "bad_id",
    [
        "../skills/abc12345",  # subsystem traversal (the reported vector)
        "abc/def",             # path separator
        "abc\\def",            # backslash path separator
        "..",                  # parent reference
        "deadbeef0",           # 9 chars — wrong length
        "deadbee",             # 7 chars — wrong length
        "/etc/passwd",         # absolute-ish path
    ],
)
def test_memory_id_boundary_rejects_malformed(client, home, bad_id):
    # Malformed ids never reach write_approval — 400 on both surfaces.
    assert client.post(
        f"{_MEM_PREFIX}/reject", json={"id": bad_id}, headers=_SHARED_HEADER
    ).status_code == 400
    assert client.post(
        f"{_MEM_PREFIX}/approve", json={"id": bad_id}, headers=_SHARED_HEADER
    ).status_code == 400


def test_memory_id_boundary_allows_real_staged_id_after_traversal_attempt(
    client, home
):
    # A real staged memory id is still accepted right after a rejected
    # traversal attempt — the allowlist does not lock out legitimate use.
    rec = _stage_memory(content="legitimate memory entry")
    bad = client.post(
        f"{_MEM_PREFIX}/reject",
        json={"id": "../skills/abc12345"},
        headers=_SHARED_HEADER,
    )
    assert bad.status_code == 400
    good = client.post(
        f"{_MEM_PREFIX}/reject", json={"id": rec["id"]}, headers=_SHARED_HEADER
    )
    assert good.status_code == 200
    assert good.json()["rejected"] == 1


# ===========================================================================
# PUT /memory/approval — toggle the memory.write_approval gate
# ===========================================================================


def test_approval_toggle_persists_and_reflected(client, home):
    assert wa.write_approval_enabled(wa.MEMORY) is False

    r = client.put(
        f"{_MEM_PREFIX}/approval", json={"enabled": True}, headers=_SHARED_HEADER
    )
    assert r.status_code == 200
    assert r.json() == {"enabled": True}

    # Persisted to config.yaml ...
    import yaml as _yaml

    with open(home / "config.yaml", encoding="utf-8") as f:
        cfg = _yaml.safe_load(f)
    assert cfg["memory"]["write_approval"] is True
    # ... and reflected in-process by write_approval_enabled ...
    assert wa.write_approval_enabled(wa.MEMORY) is True
    # ... and by the pending response immediately.
    pending = client.get(f"{_MEM_PREFIX}/pending", headers=_SHARED_HEADER).json()
    assert pending["approval_enabled"] is True

    # Toggle back off.
    r2 = client.put(
        f"{_MEM_PREFIX}/approval", json={"enabled": False}, headers=_SHARED_HEADER
    )
    assert r2.status_code == 200
    assert r2.json() == {"enabled": False}
    assert wa.write_approval_enabled(wa.MEMORY) is False


def test_approval_toggle_requires_token(client, home):
    assert client.put(
        f"{_MEM_PREFIX}/approval", json={"enabled": True}
    ).status_code == 401
