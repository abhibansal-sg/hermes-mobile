"""Device-token REST endpoints under /api/plugins/hermes-mobile/devices*.

Moved from ``tests/hermes_cli/test_device_tokens.py`` in the ABH-88 de-patch
(W1): the issue/list/revoke route handlers moved verbatim to
``plugins/hermes-mobile/dashboard/api.py``, mounted at
``/api/plugins/hermes-mobile/`` by ``web_server._mount_plugin_api_routes()``.
W2b moved the registry module too: ``hermes_cli/device_tokens.py`` is now
``plugins/hermes-mobile/device_tokens.py`` (unit tests in
``tests/plugins/hermes_mobile/test_device_tokens.py``), and device tokens are
only accepted by the auth gates once the plugin wires the registry into the
``token_auth`` seam — hence ``wired_token_auth`` on every test that sends a
device token through web_server auth.

MIGRATION SAFETY IS THE OVERRIDING CONSTRAINT. The LEGACY-TOKEN REGRESSION
tests run FIRST (and are named to sort first): the shared token MUST keep
authenticating the REST paths unchanged, both before AND after device tokens
exist. Device-token checks are additive at the auth layer — a device-token
miss falls through exactly as before — while scoped endpoint semantics decide
what a matched device may do.

All tests run in-process via FastAPI TestClient with a throwaway HERMES_HOME
so the registry never touches ~/.hermes.
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from tests.plugins.hermes_mobile.conftest import load_plugin_module

device_tokens = load_plugin_module("device_tokens")

# Mutates web_server.app.state — share the dashboard app-state xdist group so it
# doesn't race other app-state files (per the repo convention).
pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

_PREFIX = "/api/plugins/hermes-mobile"

_SHARED_HEADER = {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}
_SHARED_BEARER = {"Authorization": f"Bearer {web_server._SESSION_TOKEN}"}


@pytest.fixture
def home(monkeypatch, tmp_path):
    """Throwaway HERMES_HOME so device_tokens.json never touches ~/.hermes."""
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


# ===========================================================================
# 0. LEGACY-TOKEN REGRESSION — runs FIRST. The shared token authenticates every
#    REST path unchanged, with AND without device tokens issued.
# ===========================================================================


def test_aaa_legacy_shared_token_still_authenticates_rest(client, home):
    """The shared-token header path is unchanged: it lists devices fine."""
    r = client.get(f"{_PREFIX}/devices", headers=_SHARED_HEADER)
    assert r.status_code == 200
    assert r.json() == {"devices": []}


def test_aab_legacy_bearer_token_still_authenticates_rest(client, home):
    """The legacy Bearer fallback still authenticates."""
    r = client.get(f"{_PREFIX}/devices", headers=_SHARED_BEARER)
    assert r.status_code == 200


def test_aac_shared_token_still_works_after_device_issued(client, home):
    """Issuing a device token does NOT break the shared token (additive)."""
    issued = client.post(
        f"{_PREFIX}/devices/issue", json={"device_name": "Phone A"}, headers=_SHARED_HEADER
    )
    assert issued.status_code == 200
    # Shared token still authenticates after a device exists.
    r = client.get(f"{_PREFIX}/devices", headers=_SHARED_HEADER)
    assert r.status_code == 200
    assert len(r.json()["devices"]) == 1
    # And the unit-level helper still accepts the shared token directly.
    assert device_tokens.match(web_server._SESSION_TOKEN) is None  # shared != device


def test_aad_no_credential_is_rejected(client, home):
    assert client.get(f"{_PREFIX}/devices").status_code == 401


# ===========================================================================
# 1. Endpoint round-trip: issue → list → revoke → revoked-token 401
# ===========================================================================


def test_issue_list_revoke_round_trip(client, home):
    # Issue two devices.
    r1 = client.post(
        f"{_PREFIX}/devices/issue", json={"device_name": "Phone A"}, headers=_SHARED_HEADER
    )
    assert r1.status_code == 200
    a = r1.json()
    assert "token" in a and a["device_id"].startswith("dev_")

    r2 = client.post(
        f"{_PREFIX}/devices/issue", json={"device_name": "Phone B"}, headers=_SHARED_HEADER
    )
    b = r2.json()

    # List shows both, sorted last_seen desc, NO token/token_hash.
    lst = client.get(f"{_PREFIX}/devices", headers=_SHARED_HEADER).json()["devices"]
    assert len(lst) == 2
    for row in lst:
        assert "token" not in row
        assert "token_hash" not in row
        assert "token_prefix" in row and len(row["token_prefix"]) == 8
        assert "created_at" in row and "last_seen" in row
        assert row["scopes"] == ["chat", "approve"]
    # Most-recent (B) first.
    assert lst[0]["device_id"] == b["device_id"]

    # Revoke A.
    rev = client.delete(f"{_PREFIX}/devices/{a['device_id']}", headers=_SHARED_HEADER)
    assert rev.status_code == 200
    assert rev.json()["revoked"] is True
    assert rev.json()["device_id"] == a["device_id"]
    assert rev.json()["sockets_closed"] == 0  # no live WS in this test

    lst2 = client.get(f"{_PREFIX}/devices", headers=_SHARED_HEADER).json()["devices"]
    assert [d["device_id"] for d in lst2] == [b["device_id"]]


def test_revoke_unknown_device_404(client, home):
    r = client.delete(f"{_PREFIX}/devices/dev_ghost", headers=_SHARED_HEADER)
    assert r.status_code == 404
    assert r.json()["error"] == "unknown device"


def test_revoke_persist_failure_500_but_token_dead(
    client, home, monkeypatch, wired_token_auth
):
    """Codex P2 at the edge: when the registry write fails on revoke, the endpoint
    returns 500 ``{"error":"revocation persist failed"}`` (NOT a false 200
    'revoked'), AND the device token no longer authenticates in-process (deny-set),
    AND the shared token is unaffected."""
    issued = client.post(
        f"{_PREFIX}/devices/issue", json={"device_name": "x"}, headers=_SHARED_HEADER
    ).json()
    dtok = issued["token"]
    assert client.get(
        f"{_PREFIX}/devices", headers={"X-Hermes-Session-Token": dtok}
    ).status_code == 200

    # Make the persist fail only for the revoke write.
    monkeypatch.setattr(device_tokens, "_save", lambda entries: False)
    rev = client.delete(f"{_PREFIX}/devices/{issued['device_id']}", headers=_SHARED_HEADER)
    assert rev.status_code == 500
    body = rev.json()
    assert body["revoked"] is True  # honest: revoked in-process
    assert body["error"] == "revocation persist failed"
    assert body["device_id"] == issued["device_id"]

    # The token is dead despite the failed write.
    assert client.get(
        f"{_PREFIX}/devices", headers={"X-Hermes-Session-Token": dtok}
    ).status_code == 401
    # The shared token still authenticates.
    assert client.get(f"{_PREFIX}/devices", headers=_SHARED_HEADER).status_code == 200


def test_issue_persist_failure_500_and_no_token_returned(client, home, monkeypatch):
    """Codex P2 issue-side honesty: when the registry write fails on issue, the
    endpoint returns 500 ``{"error":"registry persist failed"}`` and NEVER returns
    a token (an un-persisted token would be unusable). The shared token is
    unaffected, and nothing was persisted."""
    # Force the persist to fail for the issue write.
    monkeypatch.setattr(device_tokens, "_save", lambda entries: False)
    r = client.post(
        f"{_PREFIX}/devices/issue", json={"device_name": "x"}, headers=_SHARED_HEADER
    )
    assert r.status_code == 500
    body = r.json()
    assert body["error"] == "registry persist failed"
    assert "token" not in body  # the dangerous thing never leaks

    # The shared token still authenticates, and the registry is empty (the failed
    # write left nothing behind).
    lst = client.get(f"{_PREFIX}/devices", headers=_SHARED_HEADER)
    assert lst.status_code == 200
    assert lst.json() == {"devices": []}


def test_issue_registry_limit_returns_409(client, home, monkeypatch):
    monkeypatch.setattr(device_tokens, "_MAX_DEVICES", 1)
    assert client.post(
        f"{_PREFIX}/devices/issue",
        json={"device_name": "Phone A"},
        headers=_SHARED_HEADER,
    ).status_code == 200

    r = client.post(
        f"{_PREFIX}/devices/issue",
        json={"device_name": "Phone B"},
        headers=_SHARED_HEADER,
    )
    assert r.status_code == 409
    assert r.json() == {"error": "device limit reached", "max_devices": 1}


def test_device_token_cannot_issue_another_device(client, home, wired_token_auth):
    issued = client.post(
        f"{_PREFIX}/devices/issue", json={"device_name": "x"}, headers=_SHARED_HEADER
    ).json()

    r = client.post(
        f"{_PREFIX}/devices/issue",
        json={"device_name": "nested"},
        headers={"X-Hermes-Session-Token": issued["token"]},
    )

    assert r.status_code == 403


def test_device_token_authenticates_rest_then_401_after_revoke(
    client, home, wired_token_auth
):
    issued = client.post(
        f"{_PREFIX}/devices/issue", json={"device_name": "x"}, headers=_SHARED_HEADER
    ).json()
    dtok = issued["token"]

    # Device token authenticates via header AND via Bearer.
    assert client.get(
        f"{_PREFIX}/devices", headers={"X-Hermes-Session-Token": dtok}
    ).status_code == 200
    assert client.get(
        f"{_PREFIX}/devices", headers={"Authorization": f"Bearer {dtok}"}
    ).status_code == 200

    # Revoke → the device token now 401s on REST.
    client.delete(f"{_PREFIX}/devices/{issued['device_id']}", headers=_SHARED_HEADER)
    assert client.get(
        f"{_PREFIX}/devices", headers={"X-Hermes-Session-Token": dtok}
    ).status_code == 401
    # ...but the SHARED token is unaffected.
    assert client.get(f"{_PREFIX}/devices", headers=_SHARED_HEADER).status_code == 200


def test_device_token_can_only_revoke_itself(client, home, wired_token_auth):
    a = client.post(
        f"{_PREFIX}/devices/issue", json={"device_name": "A"}, headers=_SHARED_HEADER
    ).json()
    b = client.post(
        f"{_PREFIX}/devices/issue", json={"device_name": "B"}, headers=_SHARED_HEADER
    ).json()

    r_other = client.delete(
        f"{_PREFIX}/devices/{b['device_id']}",
        headers={"X-Hermes-Session-Token": a["token"]},
    )
    assert r_other.status_code == 403
    assert device_tokens.match(b["token"]) is not None

    r_self = client.delete(
        f"{_PREFIX}/devices/{a['device_id']}",
        headers={"X-Hermes-Session-Token": a["token"]},
    )
    assert r_self.status_code == 200
    assert device_tokens.match(a["token"]) is None


# ===========================================================================
# 2. Auth on every endpoint (bad/absent token → 401)
# ===========================================================================


@pytest.mark.parametrize(
    "method,path",
    [
        ("post", f"{_PREFIX}/devices/issue"),
        ("get", f"{_PREFIX}/devices"),
        ("delete", f"{_PREFIX}/devices/dev_x"),
    ],
)
def test_endpoints_require_token(client, home, method, path):
    fn = getattr(client, method)
    kwargs = {"json": {}} if method == "post" else {}
    assert fn(path, **kwargs).status_code == 401
    # A bogus token is also rejected.
    bad = {"X-Hermes-Session-Token": "totally-bogus"}
    assert fn(path, headers=bad, **kwargs).status_code == 401


def test_device_id_path_traversal_is_safe(client, home):
    """A traversal-style device_id is just an unknown key → 404, never escapes
    the registry (the registry is a dict keyed by opaque ids; there is no path
    join on device_id)."""
    for evil in ["..%2F..%2Fetc", "dev_..", "dev_%2e%2e"]:
        r = client.delete(f"{_PREFIX}/devices/{evil}", headers=_SHARED_HEADER)
        # 404 = unknown opaque key (no file path is ever built from device_id);
        # 405 = a slash-decoded value routed off the {device_id} segment. Either
        # way NOTHING is deleted and no path escape occurs.
        assert r.status_code in (404, 400, 405)
    # The registry file is untouched / still parseable.
    if (home / "device_tokens.json").exists():
        json.loads((home / "device_tokens.json").read_text())


def test_corrupt_registry_list_returns_empty_not_500(client, home):
    (home / "device_tokens.json").write_text("garbage{")
    r = client.get(f"{_PREFIX}/devices", headers=_SHARED_HEADER)
    assert r.status_code == 200
    assert r.json() == {"devices": []}
