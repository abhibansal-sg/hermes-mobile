from __future__ import annotations

from fastapi import FastAPI
from fastapi.testclient import TestClient

from hermes_state import SessionDB
from tests.plugins.hermes_mobile.conftest import load_plugin_module


def _client(tmp_path, monkeypatch):
    import hermes_state

    db_path = tmp_path / "state.db"
    seed = SessionDB(db_path=db_path)
    seed.create_session("s", source="test")
    for i in range(1, 121):
        seed.append_message("s", role="user" if i % 2 else "assistant", content=f"message {i}")
    seed._conn.close()

    monkeypatch.setattr(hermes_state, "DEFAULT_DB_PATH", db_path, raising=False)
    api = load_plugin_module("dashboard.api")
    monkeypatch.setattr(api, "_has_dashboard_api_auth", lambda request: True)

    app = FastAPI()
    app.include_router(api.router, prefix="/api/plugins/hermes-mobile")
    return TestClient(app), api


def test_around_route_returns_bounded_window_and_metadata(tmp_path, monkeypatch):
    client, _api = _client(tmp_path, monkeypatch)

    response = client.get(
        "/api/plugins/hermes-mobile/sessions/s/messages/around?around=60&radius=2"
    )

    assert response.status_code == 200
    body = response.json()
    assert [m["id"] for m in body["messages"]] == [58, 59, 60, 61, 62]
    assert body["page"] == {
        "oldest_id": 58,
        "has_more_before": True,
        "has_more_after": True,
        "target_found": True,
        "radius": 2,
    }


def test_around_route_clamps_radius(tmp_path, monkeypatch):
    client, _api = _client(tmp_path, monkeypatch)

    response = client.get(
        "/api/plugins/hermes-mobile/sessions/s/messages/around?around=60&radius=999"
    )

    assert response.status_code == 200
    body = response.json()
    assert body["page"]["radius"] == 100
    assert len(body["messages"]) == 120
    assert body["messages"][59]["id"] == 60


def test_around_route_target_not_found_is_truthful_empty_page(tmp_path, monkeypatch):
    client, _api = _client(tmp_path, monkeypatch)

    response = client.get(
        "/api/plugins/hermes-mobile/sessions/s/messages/around?around=999&radius=3"
    )

    assert response.status_code == 200
    body = response.json()
    assert body["messages"] == []
    assert body["page"]["target_found"] is False
    assert body["page"]["oldest_id"] is None
    assert body["page"]["has_more_before"] is False
    assert body["page"]["has_more_after"] is False


def test_around_route_session_not_found_and_invalid_around(tmp_path, monkeypatch):
    client, _api = _client(tmp_path, monkeypatch)

    assert client.get(
        "/api/plugins/hermes-mobile/sessions/missing/messages/around?around=1"
    ).status_code == 404
    assert client.get(
        "/api/plugins/hermes-mobile/sessions/s/messages/around"
    ).status_code == 400
    assert client.get(
        "/api/plugins/hermes-mobile/sessions/s/messages/around?around=0"
    ).status_code == 400


def test_around_route_auth_required(tmp_path, monkeypatch):
    client, api = _client(tmp_path, monkeypatch)
    monkeypatch.setattr(api, "_has_dashboard_api_auth", lambda request: False)

    response = client.get(
        "/api/plugins/hermes-mobile/sessions/s/messages/around?around=60"
    )

    assert response.status_code == 401


def test_existing_newest_and_before_paging_remains_intact(tmp_path, monkeypatch):
    client, _api = _client(tmp_path, monkeypatch)

    newest = client.get("/api/plugins/hermes-mobile/sessions/s/messages?limit=5")
    before = client.get(
        "/api/plugins/hermes-mobile/sessions/s/messages?limit=5&before=116"
    )

    assert newest.status_code == 200
    assert [m["id"] for m in newest.json()["messages"]] == [116, 117, 118, 119, 120]
    assert newest.json()["page"] == {"oldest_id": 116, "has_more_before": True}
    assert before.status_code == 200
    assert [m["id"] for m in before.json()["messages"]] == [111, 112, 113, 114, 115]
    assert before.json()["page"] == {"oldest_id": 111, "has_more_before": True}
